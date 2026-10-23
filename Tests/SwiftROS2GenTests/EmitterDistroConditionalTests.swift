import Foundation
import Testing

@testable import SwiftROS2Gen

@Suite("SwiftEmitter distro-conditional output")
struct EmitterDistroConditionalTests {
    @Test("emits typeInfo(for:) + isLegacySchema branches for sensor_msgs/Range")
    func emitsConditionalRange() throws {
        // Hand-build the Range IR with `variance` as a jazzy-only field. The
        // pipeline merges per-distro IDL; here we assert the
        // emitter alone produces the canonical conditional shape.
        let header = FieldIR(
            ros2Name: "header", swiftName: "header",
            type: .nested(package: "std_msgs", typeName: "Header"),
            availability: .all)
        let radiationType = FieldIR(
            ros2Name: "radiation_type", swiftName: "radiationType",
            type: .primitive(.uint8), availability: .all)
        let fov = FieldIR(
            ros2Name: "field_of_view", swiftName: "fieldOfView",
            type: .primitive(.float32), availability: .all)
        let minRange = FieldIR(
            ros2Name: "min_range", swiftName: "minRange",
            type: .primitive(.float32), availability: .all)
        let maxRange = FieldIR(
            ros2Name: "max_range", swiftName: "maxRange",
            type: .primitive(.float32), availability: .all)
        let range = FieldIR(
            ros2Name: "range", swiftName: "range",
            type: .primitive(.float32), availability: .all)
        let variance = FieldIR(
            ros2Name: "variance", swiftName: "variance",
            type: .primitive(.float32),
            availability: .onlyIn(["jazzy"]))
        let ir = MessageIR(
            package: "sensor_msgs", typeName: "Range",
            fields: [header, radiationType, fov, minRange, maxRange, range, variance],
            perDistroHashes: [
                "humble": nil as String?,
                "jazzy":
                    "RIHS01_b42b62562e93cbfe9d42b82fe5994dfa3d63d7d5c90a317981703f7388adff3a",
            ],
            perDistroFieldPresence: [
                "humble": ["header", "radiation_type", "field_of_view", "min_range", "max_range", "range"],
                "jazzy": [
                    "header", "radiation_type", "field_of_view", "min_range", "max_range", "range",
                    "variance",
                ],
            ]
        )
        let actual = SwiftEmitter.emit(
            ir, sourceLabel: "common_interfaces-multi/sensor_msgs/msg/Range.msg")
        let goldenURL = try #require(
            Bundle.module.url(
                forResource: "RangeMsg", withExtension: "swift", subdirectory: "Resources/Golden"))
        let golden = try String(contentsOf: goldenURL, encoding: .utf8)
        #expect(actual == golden, "Range emit mismatch:\n--- actual ---\n\(actual)")
    }

    private func golden(_ name: String, subdirectory: String = "Resources/Golden") throws -> String {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "swift", subdirectory: subdirectory))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("emits a schemaDistro guard and a typeInfo ladder for a modern difference")
    func emitsModernVarying() throws {
        // `fixture_msgs/msg/ModernVarying` read for Humble, Jazzy, Kilted and Lyrical: a field
        // from Jazzy on (the 1.0 Humble guard), one in Kilted alone, one before Lyrical and one
        // from Lyrical on; and an action whose goal holds one.
        let fixture = try MultiDistroFixture(MultiDistroFixture.modernVarying)
        defer { fixture.remove() }
        let files = try fixture.generate()
        let message = try #require(files["FixtureMsgs/ModernVarying.swift"])
        #expect(message == (try golden("ModernVarying")), "ModernVarying emit mismatch:\n\(message)")
        let action = try #require(files["FixtureMsgs/ModernVaryingAction.swift"])
        #expect(
            action == (try golden("ModernVaryingAction", subdirectory: "Resources/Golden/Action")),
            "ModernVaryingAction emit mismatch:\n\(action)")
    }

    @Test("the CDR tests compile the ModernVarying golden")
    func cdrFixtureIsTheGolden() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SwiftROS2CDRTests/Fixtures/ModernVarying.swift")
        #expect(try String(contentsOf: fixture, encoding: .utf8) == (try golden("ModernVarying")))
    }
}
