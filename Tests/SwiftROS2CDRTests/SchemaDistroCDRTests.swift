import Foundation
import SwiftROS2CDR
import SwiftROS2Messages
import Testing

@Suite("Schema distribution of the CDR codec")
struct SchemaDistroCDRTests {
    private let emptyPayload = Data([0x00, 0x01, 0x00, 0x00])

    @Test("a legacy encoder reports Humble and a default encoder Jazzy")
    func defaultSchemaDistro() throws {
        #expect(CDREncoder().schemaDistro == .jazzy)
        #expect(CDREncoder().schemaDistroName == nil)
        #expect(CDREncoder(isLegacySchema: true).schemaDistro == .humble)
        #expect(try CDRDecoder(data: emptyPayload).schemaDistro == .jazzy)
        #expect(try CDRDecoder(data: emptyPayload).schemaDistroName == nil)
        #expect(try CDRDecoder(data: emptyPayload, isLegacySchema: true).schemaDistro == .humble)
    }

    @Test("a codec made for a distribution reports it and its legacy flag")
    func distroSchemaDistro() throws {
        for distro in ROS2Distro.allCases {
            let encoder = CDREncoder(distro: distro)
            #expect(encoder.schemaDistro == distro)
            #expect(encoder.schemaDistroName == distro.rawValue)
            #expect(encoder.isLegacySchema == distro.isLegacySchema)
            let decoder = try CDRDecoder(data: emptyPayload, distro: distro)
            #expect(decoder.schemaDistro == distro)
            #expect(decoder.schemaDistroName == distro.rawValue)
            #expect(decoder.isLegacySchema == distro.isLegacySchema)
        }
    }

    @Test("a decoder made for a distribution still validates the encapsulation header")
    func distroDecoderValidatesHeader() {
        #expect(throws: CDRDecodingError.self) {
            _ = try CDRDecoder(data: Data([0x00, 0x00, 0x00, 0x00]), distro: .lyrical)
        }
        #expect(throws: CDRDecodingError.self) {
            _ = try CDRDecoder(data: Data([0x00, 0x01]), distro: .jazzy)
        }
    }
}
