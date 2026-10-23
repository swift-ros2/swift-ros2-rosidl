import SwiftROS2Messages
import Testing

@Suite("ROS2Distro schema facts")
struct ROS2DistroTests {
    @Test("only Humble uses the legacy schema and lacks type hashes")
    func legacySchema() {
        for distro in ROS2Distro.allCases {
            #expect(distro.isLegacySchema == (distro == .humble))
            #expect(distro.supportsTypeHash == (distro != .humble))
        }
    }

    @Test("raw values are the lowercase distribution names")
    func rawValues() {
        #expect(
            ROS2Distro.allCases.map(\.rawValue) == ["humble", "jazzy", "kilted", "lyrical", "rolling"])
    }

    @Test("distributions compare in release order with Rolling greatest")
    func releaseOrder() {
        let all = ROS2Distro.allCases
        for (i, lhs) in all.enumerated() {
            for (j, rhs) in all.enumerated() {
                #expect((lhs < rhs) == (i < j), "\(lhs) < \(rhs)")
            }
            #expect(lhs <= .rolling)
        }
        #expect(all.sorted() == all)
        #expect(all.max() == .rolling)
        #expect(ROS2Distro.humble < .jazzy && ROS2Distro.kilted < .lyrical)
    }
}
