import Foundation
import Testing

@testable import SwiftROS2Gen

/// An action whose `.action` differs between distributions: its goal, result and feedback are
/// merged like messages, the five wrappers are shared, and every distribution keeps the hashes
/// of its own `.action`.
@Suite("Actions that differ between distributions")
struct ActionMergeTests {
    /// ``MultiDistroFixture/merging`` read for `distros` only.
    static func merging(
        _ distros: Set<String> = ["humble", "jazzy", "kilted", "lyrical"]
    ) throws -> MultiDistroFixture {
        try MultiDistroFixture(
            packages: MultiDistroFixture.merging.mapValues { $0.filter { distros.contains($0.key) } })
    }

    /// The parsed `fixture_msgs/action/Merge` of every distribution of ``MultiDistroFixture/merging``.
    static func mergeIDL() throws -> [String: IDLAction] {
        try MultiDistroFixture.merging["fixture_msgs"]!.mapValues { files in
            try Parser.parseAction(
                source: files["action/Merge.action"]!, file: "Merge.action", package: "fixture_msgs",
                typeName: "Merge")
        }
    }

    /// The hash of every `fixture_msgs` type in the verify plan of `runs` for `distro`, by ROS type name.
    static func hashes(_ runs: [Pipeline.PackageRun], _ distro: String) throws -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: try Pipeline.buildVerifyPlan(runs)
                .filter { $0.package == "fixture_msgs" && $0.distro == distro }
                .map { ($0.rosTypeName, $0.expectedHash) })
    }

    /// The `public struct <name>` of the action enum in `source`, through its closing brace.
    static func part(_ name: String, in source: String) throws -> Substring {
        let start = try #require(source.range(of: "    public struct \(name): CDRCodable"))
        let end = try #require(source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex))
        return source[start.lowerBound..<end.upperBound]
    }

    @Test("the goal, result and feedback are merged like messages, the wrappers are shared")
    func buildMergesTheParts() throws {
        let idl = try Self.mergeIDL()
        let action = try IRBuilder.build(perDistro: idl)
        func availability(_ part: MessageIR) -> [String: FieldAvailability] {
            Dictionary(uniqueKeysWithValues: part.fields.map { ($0.ros2Name, $0.availability) })
        }
        let modern: FieldAvailability = .onlyIn(["jazzy", "kilted", "lyrical"])
        #expect(action.goal.fields.map(\.ros2Name) == ["order", "behavior"])
        #expect(availability(action.goal) == ["order": .all, "behavior": .onlyIn(["kilted", "lyrical"])])
        // Humble's `result` next to the fields from Jazzy on: each distribution reads its own.
        #expect(action.result.fields.map(\.ros2Name) == ["result", "error_code", "error_msg"])
        #expect(
            availability(action.result) == ["result": .onlyIn(["humble"]), "error_code": modern, "error_msg": modern])
        #expect(action.feedback.fields.map(\.ros2Name) == ["progress", "tracking_error"])
        #expect(availability(action.feedback) == ["progress": .all, "tracking_error": .onlyIn(["lyrical"])])
        #expect(Set(action.result.perDistroFieldPresence.keys) == ["humble", "jazzy", "kilted", "lyrical"])

        // The constants are the union, in the order the distributions add them.
        #expect(action.result.constants.map(\.ros2Name) == ["NONE", "TIMEOUT", "GOAL_REJECTED"])
        #expect(action.result.constants.map(\.value) == [.uint(0), .uint(9003), .uint(1)])
        #expect(action.goal.constants.isEmpty && action.feedback.constants.isEmpty)

        // The wrappers reference the parts by name, so they are the same as any distribution's.
        let jazzy = try IRBuilder.build(jazzy: idl["jazzy"]!)
        #expect(action.sendGoalRequest == jazzy.sendGoalRequest)
        #expect(action.sendGoalResponse == jazzy.sendGoalResponse)
        #expect(action.getResultRequest == jazzy.getResultRequest)
        #expect(action.getResultResponse == jazzy.getResultResponse)
        #expect(action.feedbackMessage == jazzy.feedbackMessage)
    }

    @Test("each distribution has the hashes of its own .action, the wrappers and services included")
    func hashesAreProjectedPerDistribution() throws {
        let merged = try Self.merging()
        defer { merged.remove() }
        var own: [String: [String: String]] = [:]
        for distro in ["jazzy", "kilted", "lyrical"] {
            let single = try Self.merging([distro])
            defer { single.remove() }
            own[distro] = try Self.hashes(single.runs, distro)
            // The action, its 3 parts, 5 wrappers, the 2 services and their events.
            #expect(own[distro]?.count == 13)
            #expect(try Self.hashes(merged.runs, distro) == own[distro], "\(distro)")
        }

        // Kilted changes the goal and Lyrical the feedback; the result differs only on Humble
        // (and in constants, which are not hashed).
        func changes(_ suffix: String) -> [Bool] {
            let type = "fixture_msgs/action/Merge\(suffix)"
            return [own["jazzy"]![type] != own["kilted"]![type], own["kilted"]![type] != own["lyrical"]![type]]
        }
        #expect(changes("") == [true, true])
        for suffix in ["_Goal", "_SendGoal_Request", "_SendGoal", "_SendGoal_Event"] {
            #expect(changes(suffix) == [true, false], "\(suffix)")
        }
        for suffix in ["_Result", "_GetResult_Response", "_GetResult", "_GetResult_Event"] {
            #expect(changes(suffix) == [false, false], "\(suffix)")
        }
        for suffix in ["_Feedback", "_FeedbackMessage"] {
            #expect(changes(suffix) == [false, true], "\(suffix)")
        }
    }

    @Test("a merged part guards and documents the fields only some distributions have")
    func mergedPartsGuardTheirFields() throws {
        let fixture = try Self.merging()
        defer { fixture.remove() }
        let source = try #require(try fixture.generate()["FixtureMsgs/MergeAction.swift"])
        let indent = "            "
        let result = try Self.part("Result", in: source)
        #expect(result.contains("\(indent)if encoder.isLegacySchema {\n\(indent)    try result.encode(to: encoder)"))
        #expect(result.contains("\(indent)if !encoder.isLegacySchema {\n\(indent)    encoder.writeUInt16(errorCode)"))
        #expect(result.contains("        public static let GOAL_REJECTED: UInt16 = 1\n"))
        let goal = try Self.part("Goal", in: source)
        #expect(goal.contains("        /// Kilted and later only. Not encoded for an earlier distribution;"))
        #expect(
            goal.contains("\(indent)if encoder.schemaDistro >= .kilted {\n\(indent)    encoder.writeString(behavior)"))
        let feedback = try Self.part("Feedback", in: source)
        #expect(feedback.contains("        /// Lyrical and later only."))
        #expect(
            feedback.contains(
                "\(indent)if decoder.schemaDistro >= .lyrical {\n"
                    + "\(indent)    self.trackingError = try decoder.readFloat32()\n"
                    + "\(indent)} else {\n\(indent)    self.trackingError = 0.0"))
    }

    @Test("the CDR tests compile the generated Merge action and std_msgs/Empty")
    func cdrFixtureIsGenerated() throws {
        let fixture = try Self.merging()
        defer { fixture.remove() }
        // Both packages compile into the SwiftROS2CDRTests module, which has no StdMsgs module.
        let module = "SwiftROS2CDRTests"
        let files = try Pipeline.generateMulti(fixture.runs, moduleNames: ["fixture_msgs": module, "std_msgs": module])
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SwiftROS2CDRTests/Fixtures")
        for (generated, committed) in [
            ("FixtureMsgs/MergeAction.swift", "MergeAction.swift"), ("StdMsgs/EmptyMsg.swift", "EmptyMsg.swift"),
        ] {
            let file = try #require(files.first { $0.relativePath == generated })
            let url = fixtures.appendingPathComponent(committed)
            #expect(try String(contentsOf: url, encoding: .utf8) == file.contents, "\(committed)")
        }
    }

    @Test("a merged part writes and reads the placeholder byte in a distribution where it has no fields")
    func emptyMergedPartGetsSentinel() throws {
        let fixture = try MultiDistroFixture(MultiDistroFixture.shifting)
        defer { fixture.remove() }
        let source = try #require(try fixture.generate()["FixtureMsgs/ShiftAction.swift"])
        // The goal has no fields on Lyrical and the feedback none on Jazzy; each writes and reads
        // the placeholder byte at its end, there only.
        let indent = "            "
        // The end of the `if`, then of `encode(to:)` or `init(from:)`.
        let end = "\n\(indent)}\n        }\n"
        for (name, condition) in [("Goal", "schemaDistro >= .lyrical"), ("Feedback", "schemaDistro < .lyrical")] {
            let part = try Self.part(name, in: source)
            let write = "\(indent)if encoder.\(condition) {\n\(indent)    encoder.writeUInt8(0)\(end)"
            let read = "\(indent)if decoder.\(condition) {\n\(indent)    _ = try decoder.readUInt8()\(end)"
            #expect(part.contains(write), "\(name)")
            #expect(part.contains(read), "\(name)")
        }
        #expect(!(try Self.part("Result", in: source)).contains("UInt8"))

        // Each distribution has the hashes of its own `.action`, in which the part is empty.
        for (distro, files) in MultiDistroFixture.shifting {
            let single = try MultiDistroFixture([distro: files])
            defer { single.remove() }
            let own = try Self.hashes(single.runs, distro)
            #expect(own.count == 13)
            #expect(try Self.hashes(fixture.runs, distro) == own, "\(distro)")
        }
    }

    @Test("the CDR tests compile the generated Shift action")
    func cdrShiftFixtureIsGenerated() throws {
        let fixture = try MultiDistroFixture(MultiDistroFixture.shifting)
        defer { fixture.remove() }
        let generated = try #require(try fixture.generate()["FixtureMsgs/ShiftAction.swift"])
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SwiftROS2CDRTests/Fixtures/ShiftAction.swift")
        #expect(try String(contentsOf: url, encoding: .utf8) == generated)
    }

    @Test("a part field that changes type is reported at its line, with each distribution's type")
    func fieldTypeChangeNamesTheFileAndDistributions() throws {
        let fixture = try MultiDistroFixture([
            "jazzy": ["action/J.action": "int32 g\n---\nint32 r\n---\nint32 f\n"],
            "kilted": ["action/J.action": "int32 g\n---\n# now 64-bit\nint64 r\n---\nint32 f\n"],
            "lyrical": ["action/J.action": "int32 g\n---\nint64 r\n---\nint32 f\n"],
        ])
        defer { fixture.remove() }
        #expect {
            try fixture.generate()
        } throws: { error in
            "\(error)".hasSuffix(
                "/kilted/fixture_msgs/action/J.action:4: action 'J' cannot be merged across distributions: "
                    + "result field 'r' changes type: int32 in [jazzy], int64 in [kilted, lyrical]")
        }
    }

    @Test("a part whose shared fields change order is reported at the first of them in the later distribution")
    func reorderedPartFieldsAreRejected() throws {
        let fixture = try MultiDistroFixture([
            "jazzy": ["action/J.action": "int32 a\nint32 b\n---\n---\n"],
            "lyrical": ["action/J.action": "# swapped\nint32 b\nint32 a\n---\n---\n"],
        ])
        defer { fixture.remove() }
        #expect {
            try fixture.generate()
        } throws: { error in
            "\(error)".hasSuffix(
                "/lyrical/fixture_msgs/action/J.action:2: action 'J' cannot be merged across distributions: "
                    + "goal fields 'a', 'b' are in a different order in lyrical than in jazzy")
        }
    }

    @Test("a part field that skips a distribution is reported where it comes back")
    func actionFieldGapIsRejected() throws {
        let action = ["int32 g\n---\nint32 r\nint32 extra\n---\nint32 f\n", "int32 g\n---\nint32 r\n---\nint32 f\n"]
        let fixture = try MultiDistroFixture([
            "jazzy": ["action/Gap.action": action[0]], "kilted": ["action/Gap.action": action[1]],
            "lyrical": ["action/Gap.action": action[0]],
        ])
        defer { fixture.remove() }
        #expect {
            try fixture.generate()
        } throws: { error in
            "\(error)".hasSuffix(
                "/lyrical/fixture_msgs/action/Gap.action:4: action 'Gap' cannot be merged across distributions: "
                    + "result field 'extra' exists in [jazzy, lyrical] but not in [kilted] between them — a field "
                    + "must exist in one contiguous run of distributions")
        }
    }

    // MARK: - nav2_msgs/action/NavigateToPose

    /// `nav2_msgs/action/NavigateToPose` as navigation2 1.1.20 (Humble), 1.3.14 (Jazzy), 1.4.2
    /// (Kilted) and 1.5.3 (Lyrical) define it, without comments: Humble's result is
    /// `std_msgs/Empty result`, Jazzy replaces it with `error_code` and `error_msg`, Kilted and
    /// Lyrical add error-code constants, and Lyrical's feedback adds two tracking errors.
    static let navigateToPose: [String: String] = {
        let goal = "geometry_msgs/PoseStamped pose\nstring behavior_tree\n---\n"
        let feedback = """
            geometry_msgs/PoseStamped current_pose
            builtin_interfaces/Duration navigation_time
            builtin_interfaces/Duration estimated_time_remaining
            int16 number_of_recoveries
            float32 distance_remaining

            """
        let errors = "uint16 error_code\nstring error_msg\n---\n"
        let kiltedCodes =
            "uint16 UNKNOWN=9000\nuint16 FAILED_TO_LOAD_BEHAVIOR_TREE=9001\nuint16 TF_ERROR=9002\n"
            + "uint16 TIMEOUT=9003\n"
        return [
            "humble": goal + "std_msgs/Empty result\n---\n" + feedback,
            "jazzy": goal + "uint16 NONE=0\n" + errors + feedback,
            "kilted": goal + "uint16 NONE=0\n" + kiltedCodes + errors + feedback,
            "lyrical": goal + "uint16 NONE=0\nuint16 GOAL_REJECTED=1\nuint16 SEND_GOAL_FAILURE=2\n" + kiltedCodes
                + errors + feedback + "float32 position_tracking_error\nfloat32 heading_tracking_error\n",
        ]
    }()

    /// The `.msg` file of `name` in the `Resources/IDL` package directory `package`.
    static func resource(_ package: String, _ name: String) throws -> String {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "msg", subdirectory: "Resources/IDL/\(package)/msg"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// NavigateToPose read for Humble, Jazzy, Kilted and Lyrical, with the std_msgs and
    /// geometry_msgs types it reaches (the same files for every distribution).
    static func navigateToPoseFixture() throws -> MultiDistroFixture {
        let distros = ["humble", "jazzy", "kilted", "lyrical"]
        let std = [
            "msg/Header.msg": try resource("std_msgs_with_header", "Header"),
            "msg/Empty.msg": try resource("std_msgs_primitives", "Empty"),
        ]
        var geometry: [String: String] = [:]
        for name in ["PoseStamped", "Pose", "Point", "Quaternion"] {
            geometry["msg/\(name).msg"] = try resource("geometry_msgs", name)
        }
        return try MultiDistroFixture(packages: [
            "nav2_msgs": Dictionary(
                uniqueKeysWithValues: distros.map { ($0, ["action/NavigateToPose.action": navigateToPose[$0]!]) }),
            "std_msgs": Dictionary(uniqueKeysWithValues: distros.map { ($0, std) }),
            "geometry_msgs": Dictionary(uniqueKeysWithValues: distros.map { ($0, geometry) }),
        ])
    }

    /// The `type_hashes` of `share/nav2_msgs/action/NavigateToPose.json` in ros-jazzy-nav2-msgs
    /// 1.3.14, ros-kilted-nav2-msgs 1.4.2 and ros-lyrical-nav2-msgs 1.5.3 (Kilted has Jazzy's):
    /// under `"modern"` the ones all three share, under a distribution the ones it changes.
    static let rosidlHashes: [String: [String: String]] = [
        "modern": [
            "NavigateToPose_Goal": "RIHS01_22a9dffbd6733011220460bd52edbc7843c8fc86282d40bc7ad3ca176a9dec10",
            "NavigateToPose_Result": "RIHS01_ddbff7fc6d1e51d774d5defdb8398a57cb23fa8709355002d676408bb4860b85",
            "NavigateToPose_SendGoal": "RIHS01_a4fcb3bee1bf32e21a0e541a943b221aa0826996e2c98f079b47022b256f48b5",
            "NavigateToPose_SendGoal_Event": "RIHS01_bdc94ccf5fcb7263afa245871959c3df011b278ce34242a2a4eef05819aeb84e",
            "NavigateToPose_SendGoal_Request":
                "RIHS01_e9381f2acfe9fa8c4838a277d0cde28a93c483564827b9f13496b9c2092e4f09",
            "NavigateToPose_SendGoal_Response":
                "RIHS01_99f97fcbb07daf024df4b8c3f02f19ce7fa3183fcedfb76b8772a61a371a55fa",
            "NavigateToPose_GetResult": "RIHS01_c407920357d566771e8882b4ef4d1f1a84ee922d609920ccd57faa6d6e391dc5",
            "NavigateToPose_GetResult_Event": "RIHS01_a6afa5991dfffdcc45a1be7fe6d8996fbf3d209fafca2fa361039e4e0b0295db",
            "NavigateToPose_GetResult_Request":
                "RIHS01_106d3457cf0db4c4a8d3373bab3ff6aa8ba8ad99ae6392ce9784830a7d04ac93",
            "NavigateToPose_GetResult_Response":
                "RIHS01_c59f178c377de5318919c00bdbf7884cb3b185acfdffceba6c9f161e0aa3cc81",
        ],
        "jazzy": [
            "NavigateToPose": "RIHS01_a56dba8a3234a1215e610180dc703ae25bbf406dded8b54887891c9732857eab",
            "NavigateToPose_Feedback": "RIHS01_9ebc544c7d41bd8c6060b191bf9f5e4ddca6c2f61ee9e04fcb62ed5d67218a33",
            "NavigateToPose_FeedbackMessage": "RIHS01_9d1f6fa2eb975ce733b419ac2e97b134d8ff92b6478b6559feed9a50bdfd82b3",
        ],
        "lyrical": [
            "NavigateToPose": "RIHS01_8249f00686c6ae22c7854aea17fec2e47bc5fe2390e3513973eb7feb890bbd23",
            "NavigateToPose_Feedback": "RIHS01_f37016a810a4d5541cadeb74dfc5892b1cf197e84dea241276c1de178d90420b",
            "NavigateToPose_FeedbackMessage": "RIHS01_2c1b4ec1a0e3a53c9aa326aabe717670eeef0ff3d4c3351ff940613b2011728a",
        ],
    ]

    @Test("every hash of nav2_msgs/action/NavigateToPose matches rosidl's on every distribution")
    func navigateToPoseHashesMatchRosidl() throws {
        let fixture = try Self.navigateToPoseFixture()
        defer { fixture.remove() }
        let plan = try Pipeline.buildVerifyPlan(fixture.runs).filter { $0.package == "nav2_msgs" }
        // The action, its 3 parts, 5 wrappers, the 2 services and their events, on 3 distributions.
        #expect(plan.count == 39)
        for entry in plan {
            let own = Self.rosidlHashes[entry.distro == "kilted" ? "jazzy" : entry.distro]![entry.typeName]
            let expected = try #require(own ?? Self.rosidlHashes["modern"]![entry.typeName], "\(entry.typeName)")
            #expect(entry.expectedHash == expected, "\(entry.distro) \(entry.typeName)")
        }
        // Every hash the generated file carries is one of them.
        let source = try #require(try fixture.generate()["Nav2Msgs/NavigateToPoseAction.swift"])
        #expect(Set(MultiDistroFixture.hashes(in: source)).isSubset(of: plan.map(\.expectedHash)))
    }
}
