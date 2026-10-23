import Foundation
import Testing

@testable import SwiftROS2Gen

/// A package whose distributions do not all have the same types: Jazzy has the messages `A`
/// and `B`, the service `S` and the action `J`; Lyrical has only `A` and the action `L`.
private struct SplitPackage {
    let root: URL
    let runs: [Pipeline.PackageRun]

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "swift-ros2-gen-distro-presence-\(UUID().uuidString)", isDirectory: true)
        let jazzy = root.appendingPathComponent("j/foo_msgs", isDirectory: true)
        let lyrical = root.appendingPathComponent("l/foo_msgs", isDirectory: true)
        try Self.write("int32 a\n", to: jazzy.appendingPathComponent("msg/A.msg"))
        try Self.write("int32 b\n", to: jazzy.appendingPathComponent("msg/B.msg"))
        try Self.write("int32 a\n---\nint32 b\n", to: jazzy.appendingPathComponent("srv/S.srv"))
        try Self.write("int32 g\n---\nint32 r\n---\nint32 f\n", to: jazzy.appendingPathComponent("action/J.action"))
        try Self.write("int32 a\n", to: lyrical.appendingPathComponent("msg/A.msg"))
        try Self.write("int32 g\n---\nint32 r\n---\nint32 f\n", to: lyrical.appendingPathComponent("action/L.action"))
        // The action wrappers reference UUID and Time, read here as dependencies.
        func dependency(_ name: String) throws -> Pipeline.PackageRun {
            let dir = try #require(
                Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources/IDL"))
            return Pipeline.PackageRun(input: PackageInput(name: name, directory: dir), emit: false)
        }
        runs = [
            Pipeline.PackageRun(input: PackageInput(name: "foo_msgs", directory: jazzy, distro: "jazzy")),
            Pipeline.PackageRun(input: PackageInput(name: "foo_msgs", directory: lyrical, distro: "lyrical")),
            try dependency("unique_identifier_msgs"),
            try dependency("builtin_interfaces"),
        ]
    }

    static func write(_ contents: String, to file: URL) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: file, atomically: true, encoding: .utf8)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite("Distribution presence of messages, service halves and action parts")
struct PipelineDistroPresenceTests {
    /// The `distributions:` line the registry emits for `rosName`, or nil without a sample.
    private func sampleDistributions(_ registry: String, _ rosName: String) -> String? {
        let marker = "rosName: \"\(rosName)\",\n            distributions: "
        guard let range = registry.range(of: marker) else { return nil }
        return String(registry[range.upperBound...].prefix { $0 != "\n" })
    }

    @Test("an oracle sample lists only the distributions that have its type")
    func oracleSamplesCarryTheirDistributions() throws {
        let package = try SplitPackage()
        defer { package.remove() }
        let files = try Pipeline.generateOracleSamples(package.runs)
        let registry = try #require(files.first { $0.relativePath == "OracleSamples.swift" }).contents

        #expect(sampleDistributions(registry, "foo_msgs/msg/A") == "[\"jazzy\", \"lyrical\"],")
        #expect(sampleDistributions(registry, "foo_msgs/msg/B") == "[\"jazzy\"],")
        #expect(sampleDistributions(registry, "foo_msgs/srv/S_Request") == "[\"jazzy\"],")
        #expect(sampleDistributions(registry, "foo_msgs/srv/S_Response") == "[\"jazzy\"],")
        for part in ["Goal", "Result", "Feedback"] {
            #expect(sampleDistributions(registry, "foo_msgs/action/J_\(part)") == "[\"jazzy\"],")
            #expect(sampleDistributions(registry, "foo_msgs/action/L_\(part)") == "[\"lyrical\"],")
        }
        #expect(registry.contains("static let distributions: Set<String> = [\"jazzy\", \"lyrical\"]"))
        #expect(registry.contains("static func samples(for distro: String) -> [OracleSample]?"))
        #expect(registry.contains("distro == \"rolling\" && !distributions.contains(\"rolling\") ? \"lyrical\""))
    }

    @Test("service halves and action parts are not given every distribution by construction")
    func collectedDistributionsAreReal() throws {
        let package = try SplitPackage()
        defer { package.remove() }
        let collected = try Pipeline.collect(package.runs)
        let distros = Dictionary(
            collected.unresolvedIRs.map { ($0.ir.rosTypeName, $0.distros) }, uniquingKeysWith: { $1 })

        #expect(distros["foo_msgs/msg/A"] == ["jazzy", "lyrical"])
        #expect(distros["foo_msgs/msg/B"] == ["jazzy"])
        #expect(distros["foo_msgs/srv/S_Request"] == ["jazzy"])
        #expect(distros["foo_msgs/srv/S_Response"] == ["jazzy"])
        #expect(distros["foo_msgs/action/J_Goal"] == ["jazzy"])
        #expect(distros["foo_msgs/action/J_SendGoal_Request"] == ["jazzy"])
        // An action only a later run has is collected (it used to be read from the first run only).
        #expect(distros["foo_msgs/action/L_Goal"] == ["lyrical"])
        #expect(distros["foo_msgs/action/L_FeedbackMessage"] == ["lyrical"])
        for (name, set) in distros where name.hasPrefix("foo_msgs/") {
            #expect(set != Set(IRBuilder.distroOrder), "\(name) claims every distribution")
        }

        // A single run gives its own distribution to every kind, services included.
        let single = try Pipeline.collect([package.runs[0]] + package.runs[2...])
        for entry in single.unresolvedIRs where entry.ir.package == "foo_msgs" {
            #expect(entry.distros == ["jazzy"], "\(entry.ir.rosTypeName)")
        }
    }

    @Test("an action only a later distribution has is emitted")
    func laterDistroActionIsEmitted() throws {
        let package = try SplitPackage()
        defer { package.remove() }
        let paths = try Pipeline.generateMulti(package.runs).map(\.relativePath)
        #expect(paths.contains("FooMsgs/JAction.swift"))
        #expect(paths.contains("FooMsgs/LAction.swift"))
    }

    @Test("the verify plan checks each type only in the distributions that have it")
    func verifyPlanFollowsPresence() throws {
        let package = try SplitPackage()
        defer { package.remove() }
        let plan = try Pipeline.buildVerifyPlan(package.runs)
        var distros: [String: Set<String>] = [:]
        for entry in plan { distros[entry.rosTypeName, default: []].insert(entry.distro) }

        #expect(distros["foo_msgs/msg/A"] == ["jazzy", "lyrical"])
        #expect(distros["foo_msgs/msg/B"] == ["jazzy"])
        #expect(distros["foo_msgs/srv/S_Request"] == ["jazzy"])
        #expect(distros["foo_msgs/action/J_Goal"] == ["jazzy"])
        #expect(distros["foo_msgs/action/L_Goal"] == ["lyrical"])
        #expect(plan.first { $0.typeName == "L_SendGoal_Request" }?.topLevelTypeName == "L")
        #expect(plan.first { $0.typeName == "S_Response" }?.topLevelTypeName == "S")
    }

    @Test("the verify plan checks Rolling with the newest read distribution's projection")
    func verifyPlanRollingStandIn() throws {
        let package = try SplitPackage()
        defer { package.remove() }
        let rolling = try Pipeline.buildVerifyPlan(package.runs, distros: ["rolling"])
        let lyrical = try Pipeline.buildVerifyPlan(package.runs, distros: ["lyrical"])
        // The Lyrical types, labelled Rolling so the JSON is read from /opt/ros/rolling.
        #expect(rolling.allSatisfy { $0.distro == "rolling" })
        #expect(Set(rolling.map(\.rosTypeName)) == Set(lyrical.map(\.rosTypeName)))
        #expect(rolling.contains { $0.rosTypeName == "foo_msgs/msg/A" })
        #expect(!rolling.contains { $0.rosTypeName == "foo_msgs/msg/B" })
        #expect(rolling.contains { $0.rosTypeName == "foo_msgs/action/L_SendGoal" })

        // A merged type is checked with the shape generated code gives Rolling (Lyrical's),
        // and an unread Kilted between Jazzy and Lyrical with Jazzy's.
        let varying = try MultiDistroFixture(ModernHashPropagationTests.planPackage(["jazzy", "lyrical"]))
        defer { varying.remove() }
        func hashes(_ distro: String) throws -> [String: String] {
            Dictionary(
                uniqueKeysWithValues: try Pipeline.buildVerifyPlan(varying.runs, distros: [distro]).map {
                    #expect($0.distro == distro)
                    return ($0.rosTypeName, $0.expectedHash)
                })
        }
        let jazzyHashes = try hashes("jazzy")
        let lyricalHashes = try hashes("lyrical")
        #expect(try hashes("rolling") == lyricalHashes)
        #expect(try hashes("kilted") == jazzyHashes)
        #expect(jazzyHashes["fixture_msgs/msg/Plan"] != lyricalHashes["fixture_msgs/msg/Plan"])
        #expect(jazzyHashes["fixture_msgs/action/Move_SendGoal"] != lyricalHashes["fixture_msgs/action/Move_SendGoal"])
    }

    @Test("an action that differs between distributions is rejected")
    func divergentActionIsRejected() throws {
        let package = try SplitPackage()
        defer { package.remove() }
        try SplitPackage.write(
            "int64 g\n---\nint32 r\n---\nint32 f\n",
            to: package.root.appendingPathComponent("l/foo_msgs/action/J.action"))
        #expect {
            try Pipeline.generateMulti(package.runs)
        } throws: { error in
            "\(error)".contains("action 'J' differs between distros")
        }
    }
}
