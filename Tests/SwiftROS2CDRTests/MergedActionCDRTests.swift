import Foundation
import SwiftROS2CDR
import SwiftROS2Messages
import Testing

/// Wire bytes and hashes of an action whose `.action` differs between distributions, using
/// `Fixtures/MergeAction.swift` and `Fixtures/EmptyMsg.swift`: the generator's output for
/// `fixture_msgs/action/Merge` read for Humble, Jazzy, Kilted and Lyrical. `SwiftROS2GenTests`
/// checks that the fixtures match what the generator emits.
///
/// Humble's result is `std_msgs/Empty result` and later results are `uint16 error_code` and
/// `string error_msg`; Kilted adds the goal's `string behavior` and Lyrical the feedback's
/// `float32 tracking_error`.
@Suite("An action that differs between distributions")
struct MergedActionCDRTests {
    private let header: [UInt8] = [0x00, 0x01, 0x00, 0x00]

    private func encode<T: CDREncodable>(_ value: T, _ distro: ROS2Distro) throws -> [UInt8] {
        let encoder = CDREncoder(distro: distro)
        encoder.writeEncapsulationHeader()
        try value.encode(to: encoder)
        return Array(encoder.getData())
    }

    private func decode<T: CDRDecodable>(_: T.Type, _ bytes: [UInt8], _ distro: ROS2Distro) throws -> T {
        let decoder = try CDRDecoder(data: Data(bytes), distro: distro)
        let value = try T(from: decoder)
        #expect(decoder.remainingBytes == 0, "\(T.self) on \(distro)")
        return value
    }

    /// `"late"` as a CDR string: its length with the NUL, then the bytes and the NUL.
    private let late: [UInt8] = [0x05, 0x00, 0x00, 0x00] + Array("late".utf8) + [0x00]

    @Test("Humble's result is the Empty field alone, later ones the error code and message")
    func resultLayout() throws {
        #expect(
            [MergeAction.Result.NONE, MergeAction.Result.TIMEOUT, MergeAction.Result.GOAL_REJECTED] == [0, 9003, 1])
        let value = MergeAction.Result(errorCode: MergeAction.Result.TIMEOUT, errorMsg: "late")
        // Humble: std_msgs/Empty, which is rosidl's one placeholder byte.
        #expect(try encode(value, .humble) == header + [0x00])
        #expect(try decode(MergeAction.Result.self, header + [0x00], .humble) == MergeAction.Result())
        // Jazzy and later: uint16 9003, two bytes of padding, then the string.
        let modern = header + [0x2B, 0x23, 0x00, 0x00] + late
        for distro in ROS2Distro.allCases where distro >= .jazzy {
            #expect(try encode(value, distro) == modern, "\(distro)")
            #expect(try decode(MergeAction.Result.self, modern, distro) == value, "\(distro)")
        }
        // The GetResult response carries the layout of its distribution's result.
        let response = Merge_GetResult_Response(status: 4, result: value)
        #expect(try encode(response, .humble) == header + [0x04, 0x00])
        #expect(try encode(response, .jazzy) == header + [0x04, 0x00, 0x2B, 0x23] + late)
    }

    @Test("the goal's behavior is written from Kilted on")
    func goalLayout() throws {
        let value = MergeAction.Goal(order: 7, behavior: "x")
        for distro in ROS2Distro.allCases {
            let behavior: [UInt8] = distro >= .kilted ? [0x02, 0x00, 0x00, 0x00, 0x78, 0x00] : []
            let bytes = header + [0x07, 0x00, 0x00, 0x00] + behavior
            #expect(try encode(value, distro) == bytes, "\(distro)")
            let decoded = try decode(MergeAction.Goal.self, bytes, distro)
            #expect(decoded == (distro >= .kilted ? value : MergeAction.Goal(order: 7)), "\(distro)")
        }
    }

    @Test("the feedback's tracking error is written on Lyrical and later only")
    func feedbackLayout() throws {
        let value = MergeAction.Feedback(progress: 0.5, trackingError: 1.5)
        for distro in ROS2Distro.allCases {
            // 0.5 and 1.5 as little-endian float32.
            let trackingError: [UInt8] = distro >= .lyrical ? [0x00, 0x00, 0xC0, 0x3F] : []
            let bytes = header + [0x00, 0x00, 0x00, 0x3F] + trackingError
            #expect(try encode(value, distro) == bytes, "\(distro)")
            let decoded = try decode(MergeAction.Feedback.self, bytes, distro)
            #expect(decoded == (distro >= .lyrical ? value : MergeAction.Feedback(progress: 0.5)), "\(distro)")
        }
    }

    /// `A.typeInfo(for:)` through the protocol, as swift-ros2 calls it.
    private func actionInfo<A: ROS2Action>(_: A.Type, _ distro: ROS2Distro) -> ROS2ActionTypeInfo {
        A.typeInfo(for: distro)
    }

    /// Every hash of `info`, in declaration order.
    private func hashes(_ info: ROS2ActionTypeInfo) -> [String?] {
        [
            info.goalTypeHash, info.resultTypeHash, info.feedbackTypeHash, info.sendGoalRequestTypeHash,
            info.sendGoalResponseTypeHash, info.getResultRequestTypeHash, info.getResultResponseTypeHash,
            info.feedbackMessageTypeHash, info.sendGoalServiceTypeHash, info.getResultServiceTypeHash,
        ]
    }

    @Test("typeInfo(for:) gives each distribution the hashes of its own action")
    func typeInfoPerDistribution() {
        let humble = actionInfo(MergeAction.self, .humble)
        let jazzy = actionInfo(MergeAction.self, .jazzy)
        let kilted = actionInfo(MergeAction.self, .kilted)
        let lyrical = actionInfo(MergeAction.self, .lyrical)
        #expect(hashes(humble).allSatisfy { $0 == nil })
        #expect(hashes(jazzy) == hashes(MergeAction.typeInfo))
        #expect(hashes(actionInfo(MergeAction.self, .rolling)) == hashes(lyrical))
        #expect([jazzy, kilted, lyrical].allSatisfy { hashes($0).allSatisfy { $0?.hasPrefix("RIHS01_") == true } })

        // Kilted changes the goal: the goal, the SendGoal request and the SendGoal service.
        let goal = [0, 3, 8]
        // Lyrical changes the feedback: the feedback and the feedback message.
        let feedback = [2, 7]
        for i in 0..<10 {
            #expect((hashes(kilted)[i] != hashes(jazzy)[i]) == goal.contains(i), "Kilted hash \(i)")
            #expect((hashes(lyrical)[i] != hashes(kilted)[i]) == feedback.contains(i), "Lyrical hash \(i)")
        }
        // The wrapper structs agree with the action.
        #expect(Merge_SendGoal_Request.typeInfo(for: .kilted).typeHash == kilted.sendGoalRequestTypeHash)
        #expect(Merge_SendGoal_Request.typeInfo(for: .jazzy).typeHash == jazzy.sendGoalRequestTypeHash)
        #expect(Merge_FeedbackMessage.typeInfo(for: .lyrical).typeHash == lyrical.feedbackMessageTypeHash)
        #expect(Merge_FeedbackMessage.typeInfo(for: .kilted).typeHash == kilted.feedbackMessageTypeHash)
    }
}
