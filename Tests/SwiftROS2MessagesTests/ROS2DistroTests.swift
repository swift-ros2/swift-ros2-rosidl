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
}
