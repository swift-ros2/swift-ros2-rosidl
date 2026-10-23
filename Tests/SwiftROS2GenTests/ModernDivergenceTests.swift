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

    private func generate(_ bodies: [String: String]) throws -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runs = try IRBuilder.distroOrder.filter { bodies[$0] != nil }.map { distro in
            Pipeline.PackageRun(
                input: PackageInput(
                    name: "demo_msgs", directory: try writePackage(root, distro: distro, body: bodies[distro]!),
                    distro: distro))
        }
        let files = try Pipeline.generateMulti(runs)
        return try #require(files.first { $0.relativePath == "DemoMsgs/Sample.swift" }).contents
    }

    @Test("a field added in a later modern distribution gets a since guard")
    func addedFieldGetsSinceGuard() throws {
        let sample = try generate([
            "jazzy": "float32 range\n", "kilted": "float32 range\n", "lyrical": "float32 range\nfloat32 variance\n",
        ])
        #expect(
            sample.contains(
                "    /// Lyrical and later only. Not encoded for an earlier distribution; decoded there as `0.0`.\n"
                    + "    public var variance: Float\n"))
        #expect(
            sample.contains(
                "        if encoder.schemaDistro >= .lyrical {\n            encoder.writeFloat32(variance)\n"))
        #expect(
            sample.contains(
                "        if decoder.schemaDistro >= .lyrical {\n"
                    + "            self.variance = try decoder.readFloat32()\n"
                    + "        } else {\n"
                    + "            self.variance = 0.0\n"
                    + "        }\n"))
        #expect(sample.contains("        } else if distro >= .lyrical {\n            typeHash = \"RIHS01_"))
        #expect(!sample.contains("isLegacySchema"))
    }

    @Test("a field removed in a later modern distribution gets an until guard")
    func removedFieldGetsUntilGuard() throws {
        let sample = try generate([
            "humble": "float32 range\nint32 legacy 5\n", "jazzy": "float32 range\nint32 legacy 5\n",
            "lyrical": "float32 range\n",
        ])
        #expect(
            sample.contains(
                "    /// Before Lyrical only. Not encoded for Lyrical and later; decoded there as `5`.\n"
                    + "    public var legacy: Int32\n"))
        #expect(
            sample.contains("        if encoder.schemaDistro < .lyrical {\n            encoder.writeInt32(legacy)\n"))
        #expect(sample.contains("        } else {\n            self.legacy = 5\n        }\n"))
        #expect(sample.contains("        } else if distro >= .lyrical {\n"))
    }

    @Test("a field missing only from a middle distribution is rejected")
    func middleGapIsRejected() throws {
        #expect {
            try generate([
                "jazzy": "float32 range\nfloat32 variance\n", "kilted": "float32 range\n",
                "lyrical": "float32 range\nfloat32 variance\n",
            ])
        } throws: { error in
            "\(error)"
                == "demo_msgs/msg/Sample: field 'variance' exists in [jazzy, lyrical] but not in [kilted] between them — a field must exist in one contiguous run of distributions"
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
