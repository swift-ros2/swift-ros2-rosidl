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
}
