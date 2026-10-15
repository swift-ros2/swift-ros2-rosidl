import Foundation
import Testing

@testable import SwiftROS2Gen

/// Invalid defaults and constants surface as `GeneratorError.parse` at the offending line of the
/// IDL file, instead of stopping the process.
@Suite("Malformed IDL is reported as an error")
struct MalformedIDLTests {
    /// Writes `files` (path relative to a fresh directory → contents), runs `body` with the
    /// directory, and removes it afterwards.
    private static func withFiles<T>(_ files: [String: String], _ body: (URL) throws -> T) throws -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-ros2-gen-malformed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return try body(root)
    }

    /// The `ParseError` that `body` throws wrapped in `GeneratorError.parse`, or nil.
    private static func parseError(_ body: () throws -> Void) -> ParseError? {
        do {
            try body()
        } catch GeneratorError.parse(let error) {
            return error
        } catch {
            Issue.record("expected GeneratorError.parse, got \(error)")
        }
        return nil
    }

    @Test("an out-of-range message constant names the file and line")
    func messageConstant() throws {
        try Self.withFiles(["pkg_msgs/msg/Bad.msg": "uint8 OK=1\nuint8 X=300\n"]) { root in
            let error = Self.parseError {
                _ = try Pipeline.generateMulti([
                    .init(input: PackageInput(name: "pkg_msgs", directory: root.appendingPathComponent("pkg_msgs")))
                ])
            }
            #expect(error?.file.hasSuffix("pkg_msgs/msg/Bad.msg") == true)
            #expect(error?.line == 2)
            #expect(error?.message.contains("'X' value 300 out of range for uint8") == true)
        }
    }

    @Test("an invalid default in a service response names its line in the .srv file")
    func serviceResponseDefault() throws {
        let srv = "int32 a\n---\nbool ok\nuint8 code 256\n"
        try Self.withFiles(["pkg_srvs/srv/Bad.srv": srv]) { root in
            let error = Self.parseError {
                _ = try Pipeline.generateMulti([
                    .init(input: PackageInput(name: "pkg_srvs", directory: root.appendingPathComponent("pkg_srvs")))
                ])
            }
            #expect(error?.file.hasSuffix("pkg_srvs/srv/Bad.srv") == true)
            #expect(error?.line == 4)
        }
    }

    @Test("an invalid constant in an action feedback names its line in the .action file")
    func actionFeedbackConstant() throws {
        let action = "int32 order\n---\nint32 sum\n---\nint8 LOW=-200\n"
        try Self.withFiles(["pkg_actions/action/Bad.action": action]) { root in
            let error = Self.parseError {
                _ = try Pipeline.parseActionsIn(
                    run: .init(
                        input: PackageInput(name: "pkg_actions", directory: root.appendingPathComponent("pkg_actions"))
                    ))
            }
            #expect(error?.file.hasSuffix("pkg_actions/action/Bad.action") == true)
            #expect(error?.line == 5)
        }
    }

    @Test("an invalid constant of one distribution in a multi-distribution package names that file")
    func multiDistroConstant() throws {
        let files = [
            "humble/pkg_msgs/msg/Thing.msg": "uint8 X=3\n",
            "jazzy/pkg_msgs/msg/Thing.msg": "# comment\nuint8 X=-3\n",
        ]
        try Self.withFiles(files) { root in
            let error = Self.parseError {
                _ = try Pipeline.generateMulti([
                    .init(
                        input: PackageInput(
                            name: "pkg_msgs", directory: root.appendingPathComponent("humble/pkg_msgs"),
                            distro: "humble")),
                    .init(
                        input: PackageInput(
                            name: "pkg_msgs", directory: root.appendingPathComponent("jazzy/pkg_msgs"),
                            distro: "jazzy")),
                ])
            }
            #expect(error?.file == "jazzy/pkg_msgs/msg/Thing.msg")
            #expect(error?.line == 2)
        }
    }

    @Test("a parse error in a service response reports the line of the whole .srv file")
    func serviceResponseParseErrorLine() throws {
        let error = #expect(throws: ParseError.self) {
            _ = try Parser.parseService(
                source: "int32 a\n---\nbool ok\nnot_a_type!\n", file: "x.srv", package: "p", typeName: "S")
        }
        #expect(error?.line == 4)
    }
}
