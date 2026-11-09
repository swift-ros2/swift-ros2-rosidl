import Foundation
import Testing

@testable import SwiftROS2Gen

@Suite("SwiftEmitter for ActionIR")
struct ActionEmitterGoldenTests {

    /// UUID + Time IRs sufficient for resolving the wrapper-level nested
    /// references when computing wrapper hashes. Mirrors the fixture pattern
    /// in ``ActionHashGoldenTests``.
    private static func extraRegistry() -> [String: MessageIR] {
        let uuid = MessageIR(
            package: "unique_identifier_msgs", typeName: "UUID",
            fields: [
                FieldIR(
                    ros2Name: "uuid", swiftName: "uuid",
                    type: .array(element: .primitive(.uint8), length: 16))
            ]
        )
        let time = MessageIR(
            package: "builtin_interfaces", typeName: "Time",
            fields: [
                FieldIR(ros2Name: "sec", swiftName: "sec", type: .primitive(.int32)),
                FieldIR(ros2Name: "nanosec", swiftName: "nanosec", type: .primitive(.uint32)),
            ]
        )
        return [
            uuid.rosTypeName: uuid,
            time.rosTypeName: time,
        ]
    }

    /// `source` parsed as `<package>/action/<typeName>.action`, hashed for Jazzy and emitted.
    private static func emit(_ source: String, package: String, typeName: String) throws -> String {
        let idl = try Parser.parseAction(
            source: source, file: "\(typeName).action", package: package, typeName: typeName)
        var ir = try IRBuilder.build(jazzy: idl)
        IRBuilder.populateActionHashes(
            &ir, distro: "jazzy", extraRegistry: Self.extraRegistry())
        return SwiftEmitter.emit(
            ir,
            sourceLabel: "\(package)/action/\(typeName).action",
            nestedNameOverrides: [
                "unique_identifier_msgs/msg/UUID": "UniqueIdentifierUUID"
            ]
        )
    }

    private static func golden(_ name: String) throws -> String {
        let goldenURL = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "swift",
                subdirectory: "Resources/Golden/Action"
            )
        )
        return try String(contentsOf: goldenURL, encoding: .utf8)
    }

    @Test("Fibonacci.swift matches the golden byte-for-byte")
    func fibonacciGolden() throws {
        let emitted = try Self.emit(
            "int32 order\n---\nint32[] sequence\n---\nint32[] sequence\n",
            package: "example_interfaces", typeName: "Fibonacci")
        #expect(emitted == (try Self.golden("Fibonacci")))
    }

    @Test("the constants of the goal, result and feedback are emitted, as a message's are")
    func constantsGolden() throws {
        // Constants next to fields in the goal and the result (several types, a negative value
        // and a string), and constants alone in the feedback, which keeps the empty-structure
        // byte.
        let source = """
            # Goal
            uint8 MODE_FAST=0
            uint8 MODE_SAFE=1
            uint8 mode
            ---
            # Result
            int32 SUCCESSFUL=0
            int32 INVALID_GOAL=-1
            string DEFAULT_MESSAGE="done"
            int32 error_code
            string error_string
            ---
            # Feedback
            float32 MAX_PROGRESS=1.0
            bool REPORTS_PROGRESS=true

            """
        let emitted = try Self.emit(source, package: "fixture_msgs", typeName: "Coded")
        #expect(emitted == (try Self.golden("Coded")), "Coded emit mismatch:\n\(emitted)")
    }
}
