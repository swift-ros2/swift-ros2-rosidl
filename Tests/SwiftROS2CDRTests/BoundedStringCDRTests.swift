import Foundation
import XCTest

@testable import SwiftROS2CDR
@testable import SwiftROS2Messages

/// Bounded strings (`string<=N`, and arrays and sequences of them) on the wire, using
/// `Fixtures/BoundedStrings.swift`: the generator's output for `fixture_msgs/msg/BoundedStrings`
/// (`string<=5 name`, `string<=3[2] pair`, `string<=4[<=2] tags`). `SwiftROS2GenTests` checks that
/// the fixture matches what the generator emits.
///
/// rosidl counts the bound in bytes, without the trailing null.
final class BoundedStringCDRTests: XCTestCase {

    /// `name = "abcde"`, `pair = ["abc", "d"]`, `tags = ["wxyz"]`, each string at its bound or
    /// below. Every length prefix counts the trailing null.
    private static let atBound: [UInt8] =
        [0x00, 0x01, 0x00, 0x00]
        + [0x06, 0x00, 0x00, 0x00, 0x61, 0x62, 0x63, 0x64, 0x65, 0x00, 0x00, 0x00]
        + [0x04, 0x00, 0x00, 0x00, 0x61, 0x62, 0x63, 0x00]
        + [0x02, 0x00, 0x00, 0x00, 0x64, 0x00, 0x00, 0x00]
        + [0x01, 0x00, 0x00, 0x00]
        + [0x05, 0x00, 0x00, 0x00, 0x77, 0x78, 0x79, 0x7A, 0x00]

    private func encoded(_ value: BoundedStrings) throws -> Data {
        let encoder = CDREncoder()
        encoder.writeEncapsulationHeader()
        try value.encode(to: encoder)
        return encoder.getData()
    }

    private func decode(_ bytes: [UInt8]) throws -> BoundedStrings {
        try BoundedStrings(from: try CDRDecoder(data: Data(bytes)))
    }

    private func assertStringTooLong(
        _ value: BoundedStrings, field: String, maximum: Int, actual: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try encoded(value), file: file, line: line) { error in
            XCTAssertEqual(
                error as? CDRSerializationError,
                .stringTooLong(field: field, maximum: maximum, actual: actual), file: file, line: line)
        }
    }

    // MARK: - Encode

    func testStringsAtTheirBoundEncodeToGoldenBytes() throws {
        let value = BoundedStrings(name: "abcde", pair: ["abc", "d"], tags: ["wxyz"])
        XCTAssertEqual(try encoded(value), Data(Self.atBound))
    }

    func testStringOverItsBoundThrows() {
        assertStringTooLong(BoundedStrings(name: "abcdef"), field: "name", maximum: 5, actual: 6)
    }

    func testBoundCountsBytesNotCharacters() throws {
        // Two characters, four bytes: within 5.
        _ = try encoded(BoundedStrings(name: "éé"))
        // Three characters, six bytes: over 5.
        assertStringTooLong(BoundedStrings(name: "ééé"), field: "name", maximum: 5, actual: 6)
    }

    func testArrayElementOverItsBoundThrows() {
        assertStringTooLong(BoundedStrings(pair: ["abcd", ""]), field: "pair", maximum: 3, actual: 4)
    }

    func testSequenceElementOverItsBoundThrows() {
        assertStringTooLong(BoundedStrings(tags: ["abcde"]), field: "tags", maximum: 4, actual: 5)
    }

    // MARK: - Decode

    func testStringsAtTheirBoundDecode() throws {
        XCTAssertEqual(
            try decode(Self.atBound), BoundedStrings(name: "abcde", pair: ["abc", "d"], tags: ["wxyz"]))
    }

    func testStringOverItsBoundIsRejected() {
        // `name` declares 7 bytes with its null: 6 characters.
        var bytes = Self.atBound
        bytes.replaceSubrange(
            4..<14, with: [0x07, 0x00, 0x00, 0x00, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66])
        bytes.insert(0x00, at: 14)
        XCTAssertThrowsError(try decode(bytes)) { error in
            guard case CDRDecodingError.boundedStringTooLong(let count, let max) = error else {
                return XCTFail("Expected boundedStringTooLong, got \(error)")
            }
            XCTAssertEqual(count, 6)
            XCTAssertEqual(max, 5)
        }
    }

    func testSequenceElementOverItsBoundIsRejected() {
        // The only tag declares 6 bytes with its null: 5 characters, over 4.
        var bytes = Array(Self.atBound.prefix(36))
        bytes += [0x06, 0x00, 0x00, 0x00, 0x77, 0x78, 0x79, 0x7A, 0x7B, 0x00]
        XCTAssertThrowsError(try decode(bytes)) { error in
            guard case CDRDecodingError.boundedStringTooLong(let count, let max) = error else {
                return XCTFail("Expected boundedStringTooLong, got \(error)")
            }
            XCTAssertEqual(count, 5)
            XCTAssertEqual(max, 4)
        }
    }

    func testReadStringWithBoundToleratesTheEmptyLengthPrefix() throws {
        let decoder = try CDRDecoder(data: Data([0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]))
        XCTAssertEqual(try decoder.readString(maxLength: 0), "")
    }

    func testReadStringWithBoundChecksBeforeReadingThePayload() throws {
        // The prefix declares 1 GiB; the bound check fires, not the end-of-data check.
        let decoder = try CDRDecoder(data: Data([0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x40]))
        XCTAssertThrowsError(try decoder.readString(maxLength: 8)) { error in
            guard case CDRDecodingError.boundedStringTooLong = error else {
                return XCTFail("Expected boundedStringTooLong, got \(error)")
            }
        }
    }

    func testErrorDescriptions() {
        XCTAssertEqual(
            CDRSerializationError.stringTooLong(field: "name", maximum: 5, actual: 6).errorDescription,
            "Field 'name' is a string of at most 5 bytes but holds 6")
        XCTAssertEqual(
            CDRDecodingError.boundedStringTooLong(bytes: 6, max: 5).errorDescription,
            "CDR string holds 6 bytes which exceeds its bound of 5")
    }
}
