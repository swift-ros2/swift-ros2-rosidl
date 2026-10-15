import Foundation
import Testing

@testable import SwiftROS2Gen

/// `wstring` (bounded or not, alone or in an array or sequence) is rejected until the generator
/// can encode it: rosidl writes UTF-16 code units, laid out differently by the Fast-CDR based
/// RMWs and by Cyclone DDS, while the generator would write the UTF-8 `string` encoding.
@Suite("wstring")
struct WStringTests {

    @Test(
        "wstring in any field shape is rejected with its file and line",
        arguments: [
            "wstring", "wstring<=4", "wstring[]", "wstring[2]", "wstring[<=2]", "wstring<=4[]", "wstring<=4[2]",
        ])
    func parserRejectsWString(_ type: String) {
        let error = #expect(throws: ParseError.self) {
            _ = try Parser.parseMessage(
                source: "int32 count\n# comment\n\(type) text\n", file: "fixture_msgs/msg/Wide.msg",
                package: "fixture_msgs", typeName: "Wide")
        }
        #expect(error?.file == "fixture_msgs/msg/Wide.msg")
        #expect(error?.line == 3)
        #expect(error?.message == "wstring is not supported yet")
    }

    @Test("a wstring constant stays parseable: it is not part of the wire format")
    func wstringConstantIsAccepted() throws {
        let file = try Parser.parseMessage(
            source: "wstring GREETING=hello\n", file: "Fixture.msg", package: "fixture_msgs", typeName: "Fixture")
        #expect(file.fields.isEmpty)
        #expect(file.constants.count == 1)
    }

    @Test(
        "the pipeline fails with a GeneratorError for wstring in a message, a service or an action",
        arguments: [
            ("msg/Wide.msg", "int32 a\nwstring<=8 text\n", "fixture_msgs/msg/Wide.msg:2"),
            ("srv/Wide.srv", "wstring text\n---\n", "fixture_msgs/srv/Wide.srv:1"),
            ("action/Wide.action", "int32 a\nwstring[] text\n---\n---\n", "fixture_msgs/action/Wide.action:2"),
        ])
    func pipelineRejectsWString(path: String, contents: String, location: String) throws {
        let input = try TempIDLPackage.make([path: contents])
        defer { TempIDLPackage.remove(input) }
        let error = #expect(throws: GeneratorError.self) {
            _ = try Pipeline.generateMulti([.init(input: input)])
        }
        guard case .parse(let parseError)? = error else {
            Issue.record("expected GeneratorError.parse, got \(String(describing: error))")
            return
        }
        // The pipeline reports the IDL file by its path on disk, so match the tail.
        #expect(error?.description.hasSuffix("\(location): wstring is not supported yet") == true)
        #expect(parseError.message == "wstring is not supported yet")
    }
}
