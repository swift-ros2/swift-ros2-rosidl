import Foundation
import Testing

@testable import SwiftROS2Gen

@Suite("Oracle samples")
struct OracleSampleEmitterTests {
    @Test("primitive samples are fixed non-default values")
    func primitives() {
        #expect(OracleSampleEmitter.sampleExpression(.primitive(.bool), nestedNameOverrides: [:]) == "true")
        #expect(OracleSampleEmitter.sampleExpression(.primitive(.int32), nestedNameOverrides: [:]) == "-70000")
        #expect(OracleSampleEmitter.sampleExpression(.primitive(.float64), nestedNameOverrides: [:]) == "-2.25")
        #expect(OracleSampleEmitter.sampleExpression(.primitive(.string), nestedNameOverrides: [:]) == "\"swift-ros2\"")
    }

    @Test("bounded strings and sequences stay within their bounds")
    func bounds() {
        #expect(
            OracleSampleEmitter.sampleExpression(.boundedString(isWide: false, upperBound: 4), nestedNameOverrides: [:])
                == "\"swif\"")
        #expect(
            OracleSampleEmitter.sampleExpression(
                .sequence(element: .primitive(.uint8), upperBound: 1), nestedNameOverrides: [:]) == "[7]")
        #expect(
            OracleSampleEmitter.sampleExpression(
                .sequence(element: .primitive(.uint8), upperBound: 0), nestedNameOverrides: [:]) == "[]")
        #expect(
            OracleSampleEmitter.sampleExpression(
                .sequence(element: .primitive(.uint8), upperBound: nil), nestedNameOverrides: [:]) == "[7, 7]")
        #expect(
            OracleSampleEmitter.sampleExpression(
                .array(element: .primitive(.float64), length: 3), nestedNameOverrides: [:])
                == "Array(repeating: -2.25, count: 3)")
    }

    @Test("nested types call their own sample, honoring name overrides")
    func nested() {
        #expect(
            OracleSampleEmitter.sampleExpression(
                .nested(package: "unique_identifier_msgs", typeName: "UUID"),
                nestedNameOverrides: Pipeline.defaultSwiftNameOverrides)
                == "UniqueIdentifierUUID.oracleSample()")
    }

    @Test("extension sets every field")
    func extensionSetsFields() {
        let ir = MessageIR(
            package: "builtin_interfaces", typeName: "Time",
            fields: [
                FieldIR(ros2Name: "sec", swiftName: "sec", type: .primitive(.int32), availability: .all),
                FieldIR(ros2Name: "nanosec", swiftName: "nanosec", type: .primitive(.uint32), availability: .all),
            ],
            perDistroHashes: ["jazzy": "RIHS01_x"])
        let out = OracleSampleEmitter.emitExtension(ir, structName: "Time", nestedNameOverrides: [:])
        #expect(out.contains("extension Time {"))
        #expect(out.contains("var value = Time()"))
        #expect(out.contains("value.sec = -70000"))
        #expect(out.contains("value.nanosec = 70000"))
    }

    @Test("pipeline writes one file per package plus the registry")
    func pipelineFiles() throws {
        let dir = try #require(
            Bundle.module.url(forResource: "builtin_interfaces", withExtension: nil, subdirectory: "Resources/IDL"))
        let files = try Pipeline.generateOracleSamples([
            .init(input: PackageInput(name: "builtin_interfaces", directory: dir))
        ])
        #expect(files.map(\.relativePath) == ["OracleSamples+BuiltinInterfaces.swift", "OracleSamples.swift"])
        let registry = try #require(files.last)
        #expect(registry.contents.contains("rosName: \"builtin_interfaces/msg/Time\""))
        #expect(registry.contents.contains("reencode: { try oracleReencode(Time.self, $0) }"))
        #expect(registry.contents.contains("\nimport BuiltinInterfaces\n"))
    }

    @Test("dependency types get an extension only when an emitted type reaches them")
    func dependencySamplesFollowReachability() throws {
        func dir(_ name: String) throws -> URL {
            try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources/IDL"))
        }
        let builtin = Pipeline.PackageRun(
            input: PackageInput(name: "builtin_interfaces", directory: try dir("builtin_interfaces")), emit: false)

        let withHeader = try Pipeline.generateOracleSamples([
            .init(input: PackageInput(name: "std_msgs", directory: try dir("std_msgs_with_header"))), builtin,
        ])
        #expect(
            withHeader.map(\.relativePath)
                == ["OracleSamples+Dependencies.swift", "OracleSamples+StdMsgs.swift", "OracleSamples.swift"])
        let dependencies = try #require(withHeader.first)
        #expect(dependencies.contents.contains("extension Time {"))
        #expect(!dependencies.contents.contains("extension DurationMsg {"))
        let registry = try #require(withHeader.last)
        #expect(!registry.contents.contains("rosName: \"builtin_interfaces/"))

        let primitives = try Pipeline.generateOracleSamples([
            .init(input: PackageInput(name: "std_msgs", directory: try dir("std_msgs_primitives"))), builtin,
        ])
        #expect(primitives.map(\.relativePath) == ["OracleSamples+StdMsgs.swift", "OracleSamples.swift"])
        #expect(!primitives.contains { $0.contents.contains("import BuiltinInterfaces") })
    }
}
