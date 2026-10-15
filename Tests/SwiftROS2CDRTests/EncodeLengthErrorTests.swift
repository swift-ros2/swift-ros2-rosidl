import RclInterfaces
import SwiftROS2CDR
import SwiftROS2Messages
import UniqueIdentifierMsgs
import XCTest

/// A generated `encode(to:)` throws `CDRSerializationError` for a field length its IDL type
/// cannot carry, instead of stopping the process.
final class EncodeLengthErrorTests: XCTestCase {
    private func encode(_ value: some CDREncodable) throws {
        let encoder = CDREncoder()
        encoder.writeEncapsulationHeader()
        try value.encode(to: encoder)
    }

    func testFixedArrayOfWrongLengthThrows() {
        XCTAssertThrowsError(try encode(UniqueIdentifierUUID(uuid: [1, 2, 3]))) { error in
            XCTAssertEqual(
                error as? CDRSerializationError, .invalidArrayLength(field: "uuid", expected: 16, actual: 3))
        }
    }

    func testBoundedSequenceOverItsBoundThrows() {
        let descriptor = ParameterDescriptor(integerRange: [IntegerRange(), IntegerRange()])
        XCTAssertThrowsError(try encode(descriptor)) { error in
            XCTAssertEqual(
                error as? CDRSerializationError, .sequenceTooLong(field: "integerRange", maximum: 1, actual: 2))
        }
    }

    func testBoundedSequenceAtItsBoundEncodes() throws {
        try encode(ParameterDescriptor(integerRange: [IntegerRange()]))
    }

    func testErrorDescriptionNamesTheField() {
        let error = CDRSerializationError.invalidArrayLength(field: "uuid", expected: 16, actual: 3)
        XCTAssertEqual(error.errorDescription, "Field 'uuid' is a fixed-size array of 16 elements but holds 3")
    }
}
