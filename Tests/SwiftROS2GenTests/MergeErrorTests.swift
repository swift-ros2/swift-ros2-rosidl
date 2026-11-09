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

    @Test("a message whose shared fields change order is reported at its line, with both distributions")
    func messageFieldOrder() throws {
        let error = try Self.error([
            "jazzy": ["msg/Foo.msg": "int32 a\nint32 b\n"],
            "lyrical": ["msg/Foo.msg": "# swapped\nint32 b\nint32 a\n"],
        ])
        #expect(
            error?.hasSuffix(
                "/lyrical/fixture_msgs/msg/Foo.msg:2: message 'Foo' cannot be merged across distributions: "
                    + "fields 'a', 'b' are in a different order in lyrical than in jazzy") == true,
            "\(error ?? "no error")")
    }

    @Test("a service with a NaN default that is the same in every distribution is generated")
    func serviceNaNDefault() throws {
        let fixture = try MultiDistroFixture([
            "jazzy": ["srv/N.srv": "float64 x nan\n---\nint32 b\n"],
            "lyrical": ["srv/N.srv": "float64 x nan\n---\nint32 b\n"],
        ])
        defer { fixture.remove() }
        let jazzy = try MultiDistroFixture(["jazzy": ["srv/N.srv": "float64 x nan\n---\nint32 b\n"]])
        defer { jazzy.remove() }
        let files = try fixture.generate()
        let single = try jazzy.generate()
        #expect(files["FixtureMsgs/NRequest.swift"] != nil)
        for path in ["FixtureMsgs/NSrv.swift", "FixtureMsgs/NRequest.swift", "FixtureMsgs/NResponse.swift"] {
            #expect(files[path] != nil && files[path] == single[path], "\(path)")
        }
    }

    @Test("a default that is 0.0 in one distribution and -0.0 in the next is merged, the newest winning")
    func negativeZeroDefault() throws {
        let fixture = try MultiDistroFixture([
            "jazzy": ["msg/M.msg": "float64 y 0.0\n"],
            "lyrical": ["msg/M.msg": "float64 y -0.0\n"],
        ])
        defer { fixture.remove() }
        let lyrical = try MultiDistroFixture(["lyrical": ["msg/M.msg": "float64 y -0.0\n"]])
        defer { lyrical.remove() }
        let merged = try #require(try fixture.generate()["FixtureMsgs/M.swift"])
        let single = try #require(try lyrical.generate()["FixtureMsgs/M.swift"])
        #expect(merged.contains("-0.0"), "\(merged)")
        #expect(merged == single)
    }
}
