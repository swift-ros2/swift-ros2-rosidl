import Foundation
import Testing

@testable import SwiftROS2Gen

/// A field that only some modern distributions have changes the hash of every type that
/// reaches it, in those distributions only.
@Suite("Per-distribution hashes of types that reach a varying type")
struct ModernHashPropagationTests {
    static let uuid = MessageIR(
        package: "unique_identifier_msgs", typeName: "UUID",
        fields: [
            FieldIR(ros2Name: "uuid", swiftName: "uuid", type: .array(element: .primitive(.uint8), length: 16))
        ])

    /// `demo_msgs/msg/Plan` as Jazzy (`speed`) and Lyrical (`speed`, `smoothness`) define it.
    static func planIDL(lyrical: Bool) throws -> IDLFile {
        try Parser.parseMessage(
            source: lyrical ? "float64 speed\nfloat64 smoothness\n" : "float64 speed\n",
            file: "Plan.msg", package: "demo_msgs", typeName: "Plan")
    }

    /// `demo_msgs/action/Move`: a goal that holds a `Plan`, and a result and feedback that do not.
    static func moveAction() throws -> ActionIR {
        try IRBuilder.build(
            jazzy: Parser.parseAction(
                source: "Plan plan\n---\nint32 code\n---\nfloat32 progress\n", file: "Move.action",
                package: "demo_msgs", typeName: "Move"))
    }

    @Test("action hashes project nested types per distro")
    func actionHashesProjectNestedTypes() throws {
        let merged = try IRBuilder.build(perDistro: [
            "jazzy": Self.planIDL(lyrical: false), "lyrical": Self.planIDL(lyrical: true),
        ])
        var action = try Self.moveAction()
        let registry = [Self.uuid.rosTypeName: Self.uuid, ServiceDescription.time.rosTypeName: ServiceDescription.time]
        for distro in ["jazzy", "lyrical"] {
            IRBuilder.populateActionHashes(
                &action, distro: distro, extraRegistry: registry.merging([merged.rosTypeName: merged]) { $1 })
        }
        let jazzy = try #require(action.perDistroHashes["jazzy"])
        let lyrical = try #require(action.perDistroHashes["lyrical"])

        // Each distribution's hashes are those of an action built against that distribution's
        // Plan alone.
        for (distro, hashes, lyricalPlan) in [("jazzy", jazzy, false), ("lyrical", lyrical, true)] {
            let plan = try IRBuilder.build(jazzy: Self.planIDL(lyrical: lyricalPlan))
            var single = try Self.moveAction()
            IRBuilder.populateActionHashes(
                &single, distro: distro, extraRegistry: registry.merging([plan.rosTypeName: plan]) { $1 })
            #expect(single.perDistroHashes[distro] == hashes, "\(distro)")
        }

        // The goal and everything that holds it differ; the rest is shared.
        #expect(jazzy.goalHash != lyrical.goalHash)
        #expect(jazzy.sendGoalRequestHash != lyrical.sendGoalRequestHash)
        #expect(jazzy.sendGoalServiceHash != lyrical.sendGoalServiceHash)
        #expect(jazzy.resultHash == lyrical.resultHash)
        #expect(jazzy.feedbackHash == lyrical.feedbackHash)
        #expect(jazzy.sendGoalResponseHash == lyrical.sendGoalResponseHash)
        #expect(jazzy.getResultRequestHash == lyrical.getResultRequestHash)
        #expect(jazzy.getResultResponseHash == lyrical.getResultResponseHash)
        #expect(jazzy.feedbackMessageHash == lyrical.feedbackMessageHash)
        #expect(jazzy.getResultServiceHash == lyrical.getResultServiceHash)
        #expect(action.goal.perDistroHashes["lyrical"] == lyrical.goalHash)
        #expect(action.sendGoalRequest.perDistroHashes["jazzy"] == jazzy.sendGoalRequestHash)
    }

    /// `fixture_msgs` with `Plan` (Jazzy and Kilted: `speed`; Lyrical adds `smoothness`), a
    /// message, a service and an action that only hold a `Plan`.
    static func planPackage(_ distros: [String]) -> [String: [String: String]] {
        var out: [String: [String: String]] = [:]
        for distro in distros {
            out[distro] = [
                "msg/Plan.msg": distro == "lyrical" ? "float64 speed\nfloat64 smoothness\n" : "float64 speed\n",
                "msg/Holder.msg": "Plan plan\nPlan[] plans\n",
                "srv/Execute.srv": "Holder holder\n---\nbool ok\n",
                "action/Move.action": "Plan plan\n---\nint32 code\n---\nfloat32 progress\n",
            ]
        }
        return out
    }

    /// The hash of each `typeHash = "…"` / `typeHash: "…"` line of a message file, in order.
    private func messageHashes(_ source: String) -> [String] {
        source.split(separator: "\n").filter { $0.contains("typeHash") }.flatMap {
            MultiDistroFixture.hashes(in: String($0))
        }
    }

    @Test("a message containing a varying message gets a hash ladder")
    func containingMessageGetsLadder() throws {
        let fixture = try MultiDistroFixture(Self.planPackage(["jazzy", "kilted", "lyrical"]))
        defer { fixture.remove() }
        let holder = try #require(try fixture.generate()["FixtureMsgs/Holder.swift"])
        #expect(holder.contains("        } else if distro >= .lyrical {\n            typeHash = \"RIHS01_"))
        #expect(!holder.contains("distro >= .kilted"))
        // The holder's own fields are the same everywhere: no field guard.
        #expect(!holder.contains("schemaDistro"))
        #expect(!holder.contains("isLegacySchema"))
        #expect(Set(messageHashes(holder)).count == 2)
    }

    @Test("service halves and the umbrella get per-distro hashes")
    func serviceGetsPerDistroHashes() throws {
        let fixture = try MultiDistroFixture(Self.planPackage(["jazzy", "lyrical"]))
        defer { fixture.remove() }
        let files = try fixture.generate()
        let request = try #require(files["FixtureMsgs/ExecuteRequest.swift"])
        let response = try #require(files["FixtureMsgs/ExecuteResponse.swift"])
        let umbrella = try #require(files["FixtureMsgs/ExecuteSrv.swift"])
        let requestHashes = messageHashes(request)
        #expect(requestHashes.count == 2)
        #expect(response.contains("public static let typeInfo = ROS2MessageTypeInfo("))
        #expect(umbrella.contains("    public static func typeInfo(for distro: ROS2Distro) -> ROS2ServiceTypeInfo {"))
        #expect(umbrella.contains("            return typeInfo(for: .jazzy).withoutTypeHashes\n"))
        #expect(umbrella.contains("        } else if distro >= .lyrical {\n            return ROS2ServiceTypeInfo(\n"))
        #expect(umbrella.contains("    public static var typeInfo: ROS2ServiceTypeInfo { typeInfo(for: .jazzy) }"))
        // Newest first: the Lyrical request hash, then the Jazzy one, as in the request's ladder.
        let umbrellaRequestHashes = umbrella.split(separator: "\n").filter { $0.contains("requestTypeHash") }
            .flatMap { MultiDistroFixture.hashes(in: String($0)) }
        #expect(umbrellaRequestHashes == requestHashes)
        let serviceHashes = umbrella.split(separator: "\n").filter { $0.contains("serviceTypeHash") }
            .flatMap { MultiDistroFixture.hashes(in: String($0)) }
        #expect(Set(serviceHashes).count == 2)
    }

    @Test("action wrappers and the action type info get per-distro hashes")
    func actionGetsPerDistroHashes() throws {
        let fixture = try MultiDistroFixture(Self.planPackage(["jazzy", "kilted", "lyrical"]))
        defer { fixture.remove() }
        let action = try #require(try fixture.generate()["FixtureMsgs/MoveAction.swift"])
        #expect(action.contains("    public static func typeInfo(for distro: ROS2Distro) -> ROS2ActionTypeInfo {"))
        #expect(action.contains("        } else if distro >= .lyrical {\n            return ROS2ActionTypeInfo(\n"))
        #expect(!action.contains("distro >= .kilted"))
        // The SendGoal request holds the goal and gets a ladder; the other wrappers do not.
        func wrapper(_ name: String) throws -> String {
            let start = try #require(action.range(of: "public struct Move_\(name): ROS2Message"))
            let end =
                action.range(of: "\n}\n", range: start.upperBound..<action.endIndex)?.upperBound ?? action.endIndex
            return String(action[start.lowerBound..<end])
        }
        #expect(try wrapper("SendGoal_Request").contains("        } else if distro >= .lyrical {"))
        for name in ["SendGoal_Response", "GetResult_Request", "GetResult_Response", "FeedbackMessage"] {
            #expect(try wrapper(name).contains("    public static let typeInfo = ROS2MessageTypeInfo("), "\(name)")
        }
    }

    @Test("each merged per-distro hash equals the hash of a single-distro run")
    func mergedHashesEqualSingleDistroRuns() throws {
        let merged = try MultiDistroFixture(Self.planPackage(["jazzy", "kilted", "lyrical"]))
        defer { merged.remove() }
        let mergedFiles = try merged.generate()
        var single: [String: [String: String]] = [:]
        for distro in ["jazzy", "lyrical"] {
            let fixture = try MultiDistroFixture(Self.planPackage([distro]))
            defer { fixture.remove() }
            single[distro] = try fixture.generate()
        }
        #expect(mergedFiles.keys.sorted() == single["jazzy"]!.keys.sorted())
        for (path, source) in mergedFiles {
            let jazzy = MultiDistroFixture.hashes(in: single["jazzy"]![path]!)
            let lyrical = MultiDistroFixture.hashes(in: single["lyrical"]![path]!)
            let hashes = MultiDistroFixture.hashes(in: source)
            if jazzy == lyrical {
                #expect(hashes == jazzy, "\(path)")
            } else {
                // A ladder lists the Lyrical hashes (newest first) before the Jazzy ones.
                #expect(Set(hashes) == Set(jazzy + lyrical), "\(path)")
                #expect(hashes.filter { !jazzy.contains($0) } == lyrical.filter { !jazzy.contains($0) }, "\(path)")
            }
        }
        #expect(MultiDistroFixture.hashes(in: mergedFiles["FixtureMsgs/Plan.swift"]!).count == 2)
    }

    /// `dep_msgs/Plan` read for Jazzy (`speed`), Kilted and Lyrical (`speed`, `k`), and
    /// `fixture_msgs` (a message, a service and an action that hold a `Plan`) read for Jazzy and
    /// Lyrical only, or for the given distributions.
    static func splitReadPackages(
        holder: [String] = ["jazzy", "lyrical"], plan: [String] = ["jazzy", "kilted", "lyrical"]
    )
        -> [String: [String: [String: String]]]
    {
        var plans: [String: [String: String]] = [:]
        for distro in plan {
            plans[distro] = ["msg/Plan.msg": distro == "jazzy" ? "float64 speed\n" : "float64 speed\nfloat64 k\n"]
        }
        var holders: [String: [String: String]] = [:]
        for distro in holder {
            holders[distro] = [
                "msg/Holder.msg": "dep_msgs/Plan plan\n",
                "srv/Use.srv": "dep_msgs/Plan plan\n---\nbool ok\n",
                "action/Run.action": "dep_msgs/Plan plan\n---\nint32 code\n---\nfloat32 progress\n",
            ]
        }
        return ["dep_msgs": plans, "fixture_msgs": holders]
    }

    @Test("a type read for fewer distributions than a type it holds gets that type's hashes")
    func holderReadForFewerDistributions() throws {
        // Kilted encodes Plan.k (the Plan IDL read for Kilted has it), so the Kilted hash of
        // every type that holds a Plan must include it, although fixture_msgs was not read for
        // Kilted.
        let merged = try MultiDistroFixture(packages: Self.splitReadPackages())
        defer { merged.remove() }
        let files = try merged.generate()
        var single: [String: [String: String]] = [:]
        for distro in ["jazzy", "kilted"] {
            let fixture = try MultiDistroFixture(packages: Self.splitReadPackages(holder: [distro], plan: [distro]))
            defer { fixture.remove() }
            single[distro] = try fixture.generate()
        }
        for path in [
            "FixtureMsgs/Holder.swift", "FixtureMsgs/UseSrv.swift", "FixtureMsgs/UseRequest.swift",
            "FixtureMsgs/RunAction.swift",
        ] {
            let source = try #require(files[path], "\(path)")
            let jazzy = MultiDistroFixture.hashes(in: try #require(single["jazzy"]?[path]))
            let kilted = MultiDistroFixture.hashes(in: try #require(single["kilted"]?[path]))
            #expect(source.contains("distro >= .kilted {"), "\(path)")
            #expect(!source.contains("distro >= .lyrical {"), "\(path)")
            #expect(Set(MultiDistroFixture.hashes(in: source)) == Set(jazzy + kilted), "\(path)")
        }
        // The Kilted hash is the one RIHS01 gives the merged Holder projected onto Kilted.
        let collected = try Pipeline.collect(merged.runs)
        let holder = try #require(collected.unresolvedIRs.first { $0.ir.rosTypeName == "fixture_msgs/msg/Holder" })
        let kiltedHash = RIHS01.hash(holder.ir, for: "kilted", registry: collected.registry)
        #expect(
            files["FixtureMsgs/Holder.swift"]!.contains(
                "        } else if distro >= .kilted {\n            typeHash = \"\(kiltedHash)\""))
    }

    @Test("a distribution in which a message has no fields writes and reads the sentinel byte")
    func emptyShapeGetsSentinel() throws {
        let fixture = try MultiDistroFixture(MultiDistroFixture.growing)
        defer { fixture.remove() }
        let grow = try #require(try fixture.generate()["FixtureMsgs/Grow.swift"])
        #expect(
            grow.contains(
                "        if encoder.schemaDistro >= .jazzy && encoder.schemaDistro < .lyrical {\n"
                    + "            encoder.writeUInt8(0)\n        }\n    }\n"))
        #expect(
            grow.contains(
                "        if decoder.schemaDistro >= .jazzy && decoder.schemaDistro < .lyrical {\n"
                    + "            _ = try decoder.readUInt8()\n        }\n    }\n"))
        // The Jazzy hash is the one of the empty message (with the sentinel field).
        var single: [String: String] = [:]
        for (distro, body) in [("jazzy", "\n"), ("lyrical", "float64 x\n")] {
            let one = try MultiDistroFixture([distro: ["msg/Grow.msg": body]])
            defer { one.remove() }
            single[distro] = try #require(
                MultiDistroFixture.hashes(in: try one.generate()["FixtureMsgs/Grow.swift"]!).first)
        }
        #expect(
            grow.contains("        } else if distro >= .lyrical {\n            typeHash = \"\(single["lyrical"]!)\""))
        #expect(grow.contains("        } else {\n            typeHash = \"\(single["jazzy"]!)\""))

        // A field split at Humble only: the Humble-only field leaves Jazzy and later empty.
        let split = try MultiDistroFixture(["humble": ["msg/Gone.msg": "int32 old\n"], "jazzy": ["msg/Gone.msg": "\n"]])
        defer { split.remove() }
        let gone = try #require(try split.generate()["FixtureMsgs/Gone.swift"])
        #expect(gone.contains("        if !encoder.isLegacySchema {\n            encoder.writeUInt8(0)\n        }\n"))
        #expect(
            gone.contains("        if !decoder.isLegacySchema {\n            _ = try decoder.readUInt8()\n        }\n"))
    }

    @Test("the CDR tests compile the generated Grow")
    func cdrGrowFixtureIsGenerated() throws {
        let fixture = try MultiDistroFixture(MultiDistroFixture.growing)
        defer { fixture.remove() }
        let generated = try #require(try fixture.generate()["FixtureMsgs/Grow.swift"])
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SwiftROS2CDRTests/Fixtures/Grow.swift")
        #expect(try String(contentsOf: url, encoding: .utf8) == generated)
    }
}
