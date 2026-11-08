import Foundation
import Testing

@testable import SwiftROS2Gen

/// A message, service or action that cannot be merged across distributions is reported in one
/// format: the IDL file of the distribution that introduces the problem, the line, the type and
/// its part, and for a field that changes type, its type in every distribution.
@Suite("Merge errors name the file, the line and the distributions")
struct MergeErrorTests {
    /// The description of the error that generating `fixture` throws, or nil.
    static func error(_ files: [String: [String: String]]) throws -> String? {
        let fixture = try MultiDistroFixture(files)
        defer { fixture.remove() }
        do {
            _ = try fixture.generate()
            return nil
        } catch let error as GeneratorError {
            return "\(error)"
        }
    }

    @Test("a message field that changes type is reported at its line, with each distribution's type")
    func messageFieldTypeChange() throws {
        let error = try Self.error([
            "humble": ["msg/Foo.msg": "int32 a\nint32 payload\n"],
            "jazzy": ["msg/Foo.msg": "int32 a\n# widened\nint64 payload\n"],
            "kilted": ["msg/Foo.msg": "int32 a\nint64 payload\n"],
            "lyrical": ["msg/Foo.msg": "int32 a\nint32 payload\n"],
        ])
        #expect(
            error?.hasSuffix(
                "/jazzy/fixture_msgs/msg/Foo.msg:3: message 'Foo' cannot be merged across distributions: "
                    + "field 'payload' changes type: int32 in [humble, lyrical], int64 in [jazzy, kilted]") == true,
            "\(error ?? "no error")")
    }

    @Test("a service field that changes type is reported at its line, with the half and each distribution's type")
    func serviceFieldTypeChange() throws {
        let error = try Self.error([
            "jazzy": ["srv/S.srv": "int32 a\n---\nint32 b\n"],
            "kilted": ["srv/S.srv": "int32 a\n---\n# now 64-bit\nint64 b\n"],
            "lyrical": ["srv/S.srv": "int32 a\n---\nint64 b\n"],
        ])
        #expect(
            error?.hasSuffix(
                "/kilted/fixture_msgs/srv/S.srv:4: service 'S' cannot be merged across distributions: "
                    + "response field 'b' changes type: int32 in [jazzy], int64 in [kilted, lyrical]") == true,
            "\(error ?? "no error")")
    }

    @Test("action fields no one order fits are reported in the distribution that closes the loop")
    func actionFieldOrderLoop() throws {
        // No two distributions disagree directly: 'a' < 'b' in Humble, 'b' < 'c' in Jazzy and
        // 'c' < 'a' in Kilted. Lyrical, which shares none of them, adds nothing to the loop.
        let error = try Self.error([
            "humble": ["action/J.action": "int32 a\nint32 b\n---\n---\n"],
            "jazzy": ["action/J.action": "int32 b\nint32 c\n---\n---\n"],
            "kilted": ["action/J.action": "# loop\nint32 c\nint32 a\n---\n---\n"],
            "lyrical": ["action/J.action": "int32 z\n---\n---\n"],
        ])
        #expect(
            error?.hasSuffix(
                "/kilted/fixture_msgs/action/J.action:2: action 'J' cannot be merged across distributions: "
                    + "goal fields 'a', 'b', 'c' cannot be put in one order that matches every distribution") == true,
            "\(error ?? "no error")")
    }

    @Test("a service whose files differ only in comments is the oldest distribution's service")
    func serviceCommentsMayDiffer() throws {
        let fixture = try MultiDistroFixture([
            "jazzy": ["srv/S.srv": "int32 a\n---\nint32 b\n"],
            "lyrical": ["srv/S.srv": "# The request.\nint32 a\n---\n# The response.\nint32 b\n"],
        ])
        defer { fixture.remove() }
        let jazzy = try MultiDistroFixture(["jazzy": ["srv/S.srv": "int32 a\n---\nint32 b\n"]])
        defer { jazzy.remove() }
        let files = try fixture.generate()
        let single = try jazzy.generate()
        for path in ["FixtureMsgs/SSrv.swift", "FixtureMsgs/SRequest.swift", "FixtureMsgs/SResponse.swift"] {
            #expect(files[path] != nil && files[path] == single[path], "\(path)")
        }
    }
}
