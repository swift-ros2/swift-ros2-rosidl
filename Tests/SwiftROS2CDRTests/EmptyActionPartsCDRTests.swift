import Foundation
import UniqueIdentifierMsgs
import XCTest

@testable import SwiftROS2CDR
@testable import SwiftROS2Messages

/// Wire bytes of empty action parts, using `Fixtures/ActAction.swift`: the generator's output
/// for `fixture_msgs/action/Act` (empty goal, `int32 value` result, empty feedback).
/// `SwiftROS2GenTests` checks that the fixture matches what the generator emits.
///
/// rosidl gives every empty structure, including an action's goal, result and feedback, the
/// member `uint8 structure_needs_at_least_one_member` and serializes it, so an empty part is
/// one 0x00 byte on the wire.
final class EmptyActionPartsCDRTests: XCTestCase {

    private static let header: [UInt8] = [0x00, 0x01, 0x00, 0x00]

    private func encoded<T: CDREncodable>(_ value: T) throws -> Data {
        let enc = CDREncoder()
        enc.writeEncapsulationHeader()
        try value.encode(to: enc)
        return enc.getData()
    }

    func testEmptyGoalEncodesTheSentinelByte() throws {
        XCTAssertEqual(try encoded(ActAction.Goal()), Data(Self.header + [0x00]))
    }

    func testEmptyGoalDecodeConsumesTheSentinelByte() throws {
        let dec = try CDRDecoder(data: Data(Self.header + [0x00]))
        _ = try ActAction.Goal(from: dec)
        XCTAssertEqual(dec.remainingBytes, 0)
    }

    func testEmptyFeedbackEncodesAndConsumesTheSentinelByte() throws {
        XCTAssertEqual(try encoded(ActAction.Feedback()), Data(Self.header + [0x00]))
        let dec = try CDRDecoder(data: Data(Self.header + [0x00]))
        _ = try ActAction.Feedback(from: dec)
        XCTAssertEqual(dec.remainingBytes, 0)
    }

    func testNonEmptyResultHasNoSentinel() throws {
        XCTAssertEqual(
            try encoded(ActAction.Result(value: 7)), Data(Self.header + [0x07, 0x00, 0x00, 0x00]))
    }

    func testSendGoalRequestCarriesTheGoalSentinel() throws {
        let uuid = (1...16).map { UInt8($0) }
        let request = Act_SendGoal_Request(goalId: UniqueIdentifierUUID(uuid: uuid))
        let bytes = try encoded(request)
        XCTAssertEqual(bytes, Data(Self.header + uuid + [0x00]))
        let dec = try CDRDecoder(data: bytes)
        XCTAssertEqual(try Act_SendGoal_Request(from: dec), request)
        XCTAssertEqual(dec.remainingBytes, 0)
    }

    func testFeedbackMessageCarriesTheFeedbackSentinel() throws {
        let uuid = Array(repeating: UInt8(0xAB), count: 16)
        let message = Act_FeedbackMessage(goalId: UniqueIdentifierUUID(uuid: uuid))
        let bytes = try encoded(message)
        XCTAssertEqual(bytes, Data(Self.header + uuid + [0x00]))
        let dec = try CDRDecoder(data: bytes)
        XCTAssertEqual(try Act_FeedbackMessage(from: dec), message)
        XCTAssertEqual(dec.remainingBytes, 0)
    }
}
