import Foundation
import Testing

@testable import SwiftROS2Gen

@Suite("Source labels and IDL directories")
struct SourceLabelTests {
    /// Writes `files` under a fresh directory named `name`, runs `body` with it, and removes it.
    private static func withFiles<T>(
        named name: String, _ files: [String: String], _ body: (URL) throws -> T
    ) throws -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-ros2-gen-labels-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return try body(root)
    }

    private static let package = [
        "demo_msgs/msg/Point.msg": "float64 x\n",
        "demo_msgs/srv/Reset.srv": "---\nbool ok\n",
        "demo_msgs/action/Count.action": "int32 to\n---\nint32 reached\n---\nint32 at\n",
    ]

    private static func sourceLines(_ files: [GeneratedFile]) -> [String: String] {
        var lines: [String: String] = [:]
        for file in files {
            lines[file.relativePath] = file.contents.split(separator: "\n").first { $0.hasPrefix("// Source: ") }
                .map(String.init)
        }
        return lines
    }

    /// The fixture packages an action references, as dependency-only runs.
    private static func actionDependencies() throws -> [Pipeline.PackageRun] {
        try ["builtin_interfaces", "unique_identifier_msgs"].map { name in
            let url = try #require(
                Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources/IDL"))
            return .init(input: PackageInput(name: name, directory: url), emit: false)
        }
    }

    @Test("messages, services and actions get <package>/<kind>/<Type>.<kind>, whatever the IDL directory")
    func sameRuleForEveryKind() throws {
        let dependencies = try Self.actionDependencies()
        for directoryName in ["vendor", "common_interfaces-jazzy", ".idl"] {
            let lines = try Self.withFiles(named: directoryName, Self.package) { root in
                let run = Pipeline.PackageRun(
                    input: PackageInput(name: "demo_msgs", directory: root.appendingPathComponent("demo_msgs")))
                return Self.sourceLines(try Pipeline.generateMulti([run] + dependencies))
            }
            #expect(lines["DemoMsgs/Point.swift"] == "// Source: demo_msgs/msg/Point.msg")
            #expect(lines["DemoMsgs/ResetRequest.swift"] == "// Source: demo_msgs/srv/Reset.srv")
            #expect(lines["DemoMsgs/ResetSrv.swift"] == "// Source: demo_msgs/srv/Reset.srv")
            #expect(lines["DemoMsgs/CountAction.swift"] == "// Source: demo_msgs/action/Count.action")
        }
    }

    @Test("a package read for several distributions gets the same label")
    func multiDistroLabel() throws {
        let files = [
            "humble/demo_msgs/msg/Point.msg": "float64 x\n",
            "jazzy/demo_msgs/msg/Point.msg": "float64 x\n",
        ]
        let lines = try Self.withFiles(named: "idl", files) { root in
            Self.sourceLines(
                try Pipeline.generateMulti(
                    ["humble", "jazzy"].map { distro in
                        .init(
                            input: PackageInput(
                                name: "demo_msgs", directory: root.appendingPathComponent("\(distro)/demo_msgs"),
                                distro: distro))
                    }))
        }
        #expect(lines["DemoMsgs/Point.swift"] == "// Source: demo_msgs/msg/Point.msg")
    }

    @Test("parseActionsIn rejects a missing package directory like the other kinds")
    func actionsRequireThePackageDirectory() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-ros2-gen-missing-\(UUID().uuidString)", isDirectory: true)
        do {
            _ = try Pipeline.parseActionsIn(run: .init(input: PackageInput(name: "demo_msgs", directory: missing)))
            Issue.record("expected GeneratorError.packageDirectoryMissing")
        } catch GeneratorError.packageDirectoryMissing(let url) {
            #expect(url == missing)
        } catch {
            Issue.record("expected GeneratorError.packageDirectoryMissing, got \(error)")
        }
    }
}
