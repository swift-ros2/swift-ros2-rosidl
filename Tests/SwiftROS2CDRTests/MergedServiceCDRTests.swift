import Foundation
import SwiftROS2CDR
import SwiftROS2Messages
import Testing

/// Wire bytes and hashes of a service whose `.srv` differs between distributions, using
/// `Fixtures/ProbeSrv.swift`, `Fixtures/ProbeRequest.swift` and `Fixtures/ProbeResponse.swift`:
/// the generator's output for `fixture_msgs/srv/Probe` read for Humble, Jazzy, Kilted and
/// Lyrical. `SwiftROS2GenTests` checks that the fixtures match what the generator emits.
///
/// The request is `int32 target`, plus `string legacy_mode` on Humble only and
/// `float64 tolerance 0.5` from Kilted on. The response is `uint8 status`, with `bool success`
/// before it on Lyrical, and the constants `OK` (from Kilted) and `BUSY` (from Lyrical).
@Suite("A service that differs between distributions")
struct MergedServiceCDRTests {
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

    @Test("the request has the legacy mode on Humble only and the tolerance from Kilted on")
    func requestLayout() throws {
        let value = ProbeRequest(target: 7, legacyMode: "x", tolerance: 1.5)
        let target: [UInt8] = [0x07, 0x00, 0x00, 0x00]
        // Humble: the string "x" (its length with the NUL, then the bytes) after the target.
        let humble = header + target + [0x02, 0x00, 0x00, 0x00, 0x78, 0x00]
        #expect(try encode(value, .humble) == humble)
        #expect(try decode(ProbeRequest.self, humble, .humble) == ProbeRequest(target: 7, legacyMode: "x"))
        // Jazzy: the target alone; the tolerance decodes as its IDL default, 0.5.
        #expect(try encode(value, .jazzy) == header + target)
        #expect(try decode(ProbeRequest.self, header + target, .jazzy) == ProbeRequest(target: 7))
        // Kilted and later: four bytes of padding, then 1.5 as a little-endian float64.
        let modern = header + target + [0x00, 0x00, 0x00, 0x00] + [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF8, 0x3F]
        for distro in ROS2Distro.allCases where distro >= .kilted {
            #expect(try encode(value, distro) == modern, "\(distro)")
            let decoded = try decode(ProbeRequest.self, modern, distro)
            #expect(decoded == ProbeRequest(target: 7, tolerance: 1.5), "\(distro)")
        }
    }

    @Test("the response has the success flag before the status on Lyrical and later only")
    func responseLayout() throws {
        #expect([ProbeResponse.OK, ProbeResponse.BUSY] == [0, 2])
        let value = ProbeResponse(success: true, status: ProbeResponse.BUSY)
        for distro in ROS2Distro.allCases {
            let lyrical = distro >= .lyrical
            let bytes = header + (lyrical ? [0x01, 0x02] : [0x02])
            #expect(try encode(value, distro) == bytes, "\(distro)")
            let decoded = try decode(ProbeResponse.self, bytes, distro)
            #expect(decoded == (lyrical ? value : ProbeResponse(status: ProbeResponse.BUSY)), "\(distro)")
        }
    }

    /// `S.typeInfo(for:)` through the protocol, as swift-ros2 calls it.
    private func serviceInfo<S: ROS2ServiceType>(_: S.Type, _ distro: ROS2Distro) -> ROS2ServiceTypeInfo {
        S.typeInfo(for: distro)
    }

    /// The request, response and service-level hashes of `info`.
    private func hashes(_ info: ROS2ServiceTypeInfo) -> [String?] {
        [info.requestTypeHash, info.responseTypeHash, info.serviceTypeHash]
    }

    @Test("typeInfo(for:) gives each distribution the hashes of its own service")
    func typeInfoPerDistribution() {
        let humble = serviceInfo(ProbeSrv.self, .humble)
        let jazzy = serviceInfo(ProbeSrv.self, .jazzy)
        let kilted = serviceInfo(ProbeSrv.self, .kilted)
        let lyrical = serviceInfo(ProbeSrv.self, .lyrical)
        #expect(hashes(humble).allSatisfy { $0 == nil })
        #expect(hashes(jazzy) == hashes(ProbeSrv.typeInfo))
        #expect(hashes(serviceInfo(ProbeSrv.self, .rolling)) == hashes(lyrical))
        #expect([jazzy, kilted, lyrical].allSatisfy { hashes($0).allSatisfy { $0?.hasPrefix("RIHS01_") == true } })

        // Kilted changes the request and Lyrical the response; the service changes with both.
        #expect(zip(hashes(jazzy), hashes(kilted)).map { $0 != $1 } == [true, false, true])
        #expect(zip(hashes(kilted), hashes(lyrical)).map { $0 != $1 } == [false, true, true])
        // The halves agree with the service on every distribution.
        for distro in ROS2Distro.allCases {
            let info = serviceInfo(ProbeSrv.self, distro)
            #expect(info.serviceName == "fixture_msgs/srv/Probe")
            #expect(ProbeRequest.typeInfo(for: distro).typeHash == info.requestTypeHash, "\(distro)")
            #expect(ProbeResponse.typeInfo(for: distro).typeHash == info.responseTypeHash, "\(distro)")
        }
    }
}
