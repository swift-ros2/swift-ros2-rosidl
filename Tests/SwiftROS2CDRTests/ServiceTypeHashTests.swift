import ActionMsgs
import RclInterfaces
import XCTest

@testable import SwiftROS2Messages

/// The service-level hashes of the shipped service types, pinned against the `type_hashes` of
/// the rosidl type description JSON on Jazzy, Kilted and Lyrical (identical in all three) and
/// against the key expressions rmw_zenoh_cpp declares on Lyrical.
final class ServiceTypeHashTests: XCTestCase {

    func testServiceTypeHashDefaultsToNil() {
        let info = ROS2ServiceTypeInfo(
            serviceName: "std_srvs/srv/Trigger",
            requestTypeName: "std_srvs/srv/Trigger_Request",
            responseTypeName: "std_srvs/srv/Trigger_Response"
        )
        XCTAssertNil(info.serviceTypeHash)
    }

    func testCancelGoalServiceTypeHash() {
        XCTAssertEqual(
            CancelGoalSrv.typeInfo.serviceTypeHash,
            "RIHS01_573d8b0a534451d7bc2ac8c5ffde8ac14b8593b7001175d0cd6516dcbeb8689a")
    }

    func testRclInterfacesServiceTypeHashes() {
        XCTAssertEqual(
            GetParametersSrv.typeInfo.serviceTypeHash,
            "RIHS01_bf9803d5c74cf989a5de3e0c2e99444599a627c7ff75f97b8c05b01003675cbc")
        XCTAssertEqual(
            SetParametersSrv.typeInfo.serviceTypeHash,
            "RIHS01_56eed9a67e169f9cb6c1f987bc88f868c14a8fc9f743a263bc734c154015d7e0")
        XCTAssertEqual(
            ListParametersSrv.typeInfo.serviceTypeHash,
            "RIHS01_3e6062bfbb27bfb8730d4cef2558221f51a11646d78e7bb30a1e83afac3aad9d")
    }
}
