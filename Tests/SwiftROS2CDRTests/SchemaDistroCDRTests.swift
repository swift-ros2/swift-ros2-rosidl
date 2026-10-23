import ActionMsgs
import BuiltinInterfaces
import Foundation
import RclInterfaces
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

    /// `M.typeInfo(for:)` through the protocol, as swift-ros2 calls it.
    private func messageInfo<M: ROS2MessageType>(_: M.Type, _ distro: ROS2Distro) -> ROS2MessageTypeInfo {
        M.typeInfo(for: distro)
    }

    private func serviceInfo<S: ROS2ServiceType>(_: S.Type, _ distro: ROS2Distro) -> ROS2ServiceTypeInfo {
        S.typeInfo(for: distro)
    }

    private func actionInfo<A: ROS2Action>(_: A.Type, _ distro: ROS2Distro) -> ROS2ActionTypeInfo {
        A.typeInfo(for: distro)
    }

    @Test("typeInfo(for:) defaults return typeInfo and nil hashes on Humble")
    func typeInfoDefaults() throws {
        for distro in ROS2Distro.allCases {
            let hashes = distro.supportsTypeHash

            let message = messageInfo(Time.self, distro)
            #expect(message.typeName == Time.typeInfo.typeName)
            #expect(message.typeHash == (hashes ? Time.typeInfo.typeHash : nil))
            #expect(Time.typeInfo.typeHash != nil)

            let service = serviceInfo(CancelGoalSrv.self, distro)
            let serviceDefault = CancelGoalSrv.typeInfo
            #expect(service.serviceName == serviceDefault.serviceName)
            #expect(service.requestTypeName == serviceDefault.requestTypeName)
            #expect(service.responseTypeName == serviceDefault.responseTypeName)
            #expect(service.requestTypeHash == (hashes ? serviceDefault.requestTypeHash : nil))
            #expect(service.responseTypeHash == (hashes ? serviceDefault.responseTypeHash : nil))
            #expect(service.serviceTypeHash == (hashes ? serviceDefault.serviceTypeHash : nil))

            let action = actionInfo(ActAction.self, distro)
            let actionDefault = ActAction.typeInfo
            #expect(action.actionName == actionDefault.actionName)
            let all: [(String?, String?)] = [
                (action.goalTypeHash, actionDefault.goalTypeHash),
                (action.resultTypeHash, actionDefault.resultTypeHash),
                (action.feedbackTypeHash, actionDefault.feedbackTypeHash),
                (action.sendGoalRequestTypeHash, actionDefault.sendGoalRequestTypeHash),
                (action.sendGoalResponseTypeHash, actionDefault.sendGoalResponseTypeHash),
                (action.getResultRequestTypeHash, actionDefault.getResultRequestTypeHash),
                (action.getResultResponseTypeHash, actionDefault.getResultResponseTypeHash),
                (action.feedbackMessageTypeHash, actionDefault.feedbackMessageTypeHash),
                (action.sendGoalServiceTypeHash, actionDefault.sendGoalServiceTypeHash),
                (action.getResultServiceTypeHash, actionDefault.getResultServiceTypeHash),
            ]
            for (got, base) in all {
                #expect(base != nil)
                #expect(got == (hashes ? base : nil))
            }
        }
    }

    @Test("a type's own typeInfo(for:) is what generic code gets")
    func ownTypeInfoWitness() {
        #expect(messageInfo(PerDistroFixture.self, .jazzy).typeHash == "RIHS01_jazzy")
        #expect(messageInfo(PerDistroFixture.self, .lyrical).typeHash == "RIHS01_lyrical")
        #expect(messageInfo(PerDistroFixture.self, .rolling).typeHash == "RIHS01_lyrical")
        #expect(messageInfo(PerDistroFixture.self, .humble).typeHash == nil)
    }
}

/// A message whose hash differs among distributions, written the way swift-ros2-gen emits one.
private struct PerDistroFixture: ROS2Message {
    static func typeInfo(for distro: ROS2Distro) -> ROS2MessageTypeInfo {
        let typeHash: String?
        if !distro.supportsTypeHash {
            typeHash = nil
        } else if distro >= .lyrical {
            typeHash = "RIHS01_lyrical"
        } else {
            typeHash = "RIHS01_jazzy"
        }
        return ROS2MessageTypeInfo(typeName: "fixture_msgs/msg/PerDistro", typeHash: typeHash)
    }

    static var typeInfo: ROS2MessageTypeInfo { typeInfo(for: .jazzy) }

    init() {}

    func encode(to encoder: CDREncoder) throws {
        encoder.writeUInt8(0)
    }

    init(from decoder: CDRDecoder) throws {
        _ = try decoder.readUInt8()
    }
}
