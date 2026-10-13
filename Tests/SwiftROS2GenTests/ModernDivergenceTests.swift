import Foundation
import Testing

@testable import SwiftROS2Gen

@Suite("Distro-safe generation")
struct ModernDivergenceTests {
    private func writePackage(_ root: URL, distro: String, body: String) throws -> URL {
        let pkg = root.appendingPathComponent("\(distro)/demo_msgs")
        let msg = pkg.appendingPathComponent("msg")
        try FileManager.default.createDirectory(at: msg, withIntermediateDirectories: true)
        try body.write(to: msg.appendingPathComponent("Sample.msg"), atomically: true, encoding: .utf8)
        return pkg
    }

    @Test("a field missing from one modern distribution stops generation")
    func modernDivergenceIsRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let jazzy = try writePackage(root, distro: "jazzy", body: "float32 range\nfloat32 variance\n")
        let lyrical = try writePackage(root, distro: "lyrical", body: "float32 range\n")
        do {
            _ = try Pipeline.generateMulti([
                .init(input: PackageInput(name: "demo_msgs", directory: jazzy, distro: "jazzy")),
                .init(input: PackageInput(name: "demo_msgs", directory: lyrical, distro: "lyrical")),
            ])
            Issue.record("expected modernDistroDivergence")
        } catch let error as GeneratorError {
            #expect(error.description.contains("demo_msgs/msg/Sample"))
            #expect(error.description.contains("variance"))
            #expect(error.description.contains("lyrical"))
        }
    }

    @Test("a Humble-only difference is still accepted")
    func humbleDifferenceAccepted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let humble = try writePackage(root, distro: "humble", body: "float32 range\n")
        let jazzy = try writePackage(root, distro: "jazzy", body: "float32 range\nfloat32 variance\n")
        let lyrical = try writePackage(root, distro: "lyrical", body: "float32 range\nfloat32 variance\n")
        let files = try Pipeline.generateMulti([
            .init(input: PackageInput(name: "demo_msgs", directory: humble, distro: "humble")),
            .init(input: PackageInput(name: "demo_msgs", directory: jazzy, distro: "jazzy")),
            .init(input: PackageInput(name: "demo_msgs", directory: lyrical, distro: "lyrical")),
        ])
        let sample = try #require(files.first { $0.relativePath == "DemoMsgs/Sample.swift" })
        #expect(sample.contents.contains("typeHash: distro.isLegacySchema\n                ? nil : \"RIHS01_"))
        #expect(!sample.contents.contains("switch distro"))
    }
}
