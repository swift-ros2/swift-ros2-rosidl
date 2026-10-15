import Foundation
import Testing

@testable import SwiftROS2Gen

/// Bounded strings (`string<=N`, and arrays and sequences of them) are parsed, and the generated
/// codec checks their bound.
@Suite("Bounded strings")
struct BoundedStringTests {

    // MARK: - Parsing

    private func parseField(_ type: String) throws -> IDLFieldType {
        let file = try Parser.parseMessage(
            source: "\(type) value\n", file: "Fixture.msg", package: "fixture_msgs", typeName: "Fixture")
        return file.fields[0].type
    }

    @Test("parses fixed arrays, bounded sequences and sequences of bounded strings")
    func parsesElementBounds() throws {
        let bounded = IDLFieldType.boundedString(isWide: false, upperBound: 5)
        #expect(try parseField("string<=5[3]") == .array(element: bounded, length: 3))
        #expect(try parseField("string<=5[<=2]") == .sequence(element: bounded, upperBound: 2))
        #expect(try parseField("string<=5[]") == .sequence(element: bounded, upperBound: nil))
    }

    @Test("a non-string type cannot carry a string bound")
    func rejectsBoundOnOtherTypes() {
        #expect(throws: ParseError.self) { _ = try parseField("int32<=5[]") }
        #expect(throws: ParseError.self) { _ = try parseField("string<=0[]") }
    }

    // MARK: - Generated codec

    private static func idl(_ package: String) throws -> URL {
        try #require(Bundle.module.url(forResource: package, withExtension: nil, subdirectory: "Resources/IDL"))
    }

    /// `fixture_msgs` also holds an action, which references the two dependency packages.
    private static func generateBoundedStrings() throws -> String {
        let files = try Pipeline.generateMulti([
            .init(input: PackageInput(name: "fixture_msgs", directory: try idl("fixture_msgs"))),
            .init(
                input: PackageInput(name: "unique_identifier_msgs", directory: try idl("unique_identifier_msgs")),
                emit: false),
            .init(
                input: PackageInput(name: "builtin_interfaces", directory: try idl("builtin_interfaces")),
                emit: false),
        ])
        return try #require(files.first { $0.relativePath == "FixtureMsgs/BoundedStrings.swift" }).contents
    }

    @Test("a bounded string is checked in UTF-8 bytes before it is written, and bounded when read")
    func emitsBoundCheck() throws {
        let source = try Self.generateBoundedStrings()
        #expect(source.contains("guard name.utf8.count <= 5 else {"))
        #expect(source.contains("throw CDRSerializationError.stringTooLong("))
        #expect(source.contains("self.name = try decoder.readString(maxLength: 5)"))
    }

    @Test("array and sequence elements are checked one by one")
    func emitsElementBoundCheck() throws {
        let source = try Self.generateBoundedStrings()
        #expect(source.contains("guard v.utf8.count <= 3 else {"))
        #expect(source.contains("guard v.utf8.count <= 4 else {"))
        #expect(source.contains("out.append(try decoder.readString(maxLength: 3))"))
        #expect(source.contains("out.append(try decoder.readString(maxLength: 4))"))
    }

    @Test("a string without a bound is not checked")
    func unboundedStringIsUnchecked() throws {
        let input = try TempIDLPackage.make(["msg/Plain.msg": "string text\nstring[] texts\n"])
        defer { TempIDLPackage.remove(input) }
        let files = try Pipeline.generateMulti([.init(input: input)])
        let source = try #require(files.first { $0.relativePath == "FixtureMsgs/Plain.swift" }).contents
        #expect(!source.contains("stringTooLong"))
        #expect(source.contains("self.text = try decoder.readString()"))
    }

    @Test("the compiled CDR fixture is the generator's current output")
    func cdrFixtureMatchesGenerator() throws {
        // SwiftROS2CDRTests compiles this file and checks its wire bytes.
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SwiftROS2CDRTests/Fixtures/BoundedStrings.swift")
        let committed = try String(contentsOf: fixture, encoding: .utf8)
        #expect(try Self.generateBoundedStrings() == committed)
    }
}
