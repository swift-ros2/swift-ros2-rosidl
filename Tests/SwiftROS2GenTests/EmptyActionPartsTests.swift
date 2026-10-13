import Foundation
import Testing

@testable import SwiftROS2Gen

/// An empty action goal, result or feedback carries rosidl's
/// `uint8 structure_needs_at_least_one_member`, like every other empty structure, and the
/// generated codec writes and reads it. `Resources/IDL/fixture_msgs/action/Act.action` has an
/// empty goal, an `int32 value` result and an empty feedback.
@Suite("Empty action parts")
struct EmptyActionPartsTests {

    private static func idlPackage(_ name: String, probe: String, ext: String) throws -> URL {
        let url = try #require(
            Bundle.module.url(
                forResource: probe, withExtension: ext,
                subdirectory: "Resources/IDL/\(name)/\(ext == "action" ? "action" : "msg")"))
        return url.deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func generateAct() throws -> String {
        let files = try Pipeline.generateMulti([
            .init(
                input: PackageInput(
                    name: "fixture_msgs",
                    directory: try idlPackage("fixture_msgs", probe: "Act", ext: "action"))),
            .init(
                input: PackageInput(
                    name: "unique_identifier_msgs",
                    directory: try idlPackage("unique_identifier_msgs", probe: "UUID", ext: "msg")),
                emit: false),
            .init(
                input: PackageInput(
                    name: "builtin_interfaces",
                    directory: try idlPackage("builtin_interfaces", probe: "Time", ext: "msg")),
                emit: false),
        ])
        let file = try #require(files.first { $0.relativePath == "FixtureMsgs/ActAction.swift" })
        return file.contents
    }

    /// The body of `public struct <name>` inside the emitted action enum.
    private static func innerStruct(_ name: String, in source: String) throws -> String {
        let start = try #require(source.range(of: "    public struct \(name): CDRCodable"))
        let end = try #require(source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex))
        return String(source[start.lowerBound..<end.upperBound])
    }

    @Test("empty goal and feedback write and read the sentinel byte; a non-empty result does not")
    func emptyPartsCarryTheSentinel() throws {
        let source = try Self.generateAct()
        for name in ["Goal", "Feedback"] {
            let body = try Self.innerStruct(name, in: source)
            #expect(body.contains("encoder.writeUInt8(0)"), "\(name) must write the sentinel")
            #expect(body.contains("_ = try decoder.readUInt8()"), "\(name) must read the sentinel")
        }
        let result = try Self.innerStruct("Result", in: source)
        #expect(!result.contains("writeUInt8(0)"))
    }

    @Test("the compiled CDR fixture is the generator's current output")
    func cdrFixtureMatchesGenerator() throws {
        // SwiftROS2CDRTests compiles this file and checks its wire bytes.
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SwiftROS2CDRTests/Fixtures/ActAction.swift")
        let committed = try String(contentsOf: fixture, encoding: .utf8)
        #expect(try Self.generateAct() == committed)
    }
}
