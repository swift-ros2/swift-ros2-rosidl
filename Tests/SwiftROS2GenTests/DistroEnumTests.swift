import SwiftROS2Messages
import Testing

@testable import SwiftROS2Gen

/// SwiftROS2Gen does not depend on SwiftROS2Messages, so it spells the distributions out
/// again. This keeps the two lists in step.
@Suite("Generator distributions match ROS2Distro")
struct DistroEnumTests {
    @Test("IRBuilder.distroOrder is ROS2Distro.allCases, in order")
    func distroOrderMatchesROS2Distro() {
        #expect(IRBuilder.distroOrder == ROS2Distro.allCases.map(\.rawValue))
    }

    @Test("the modern distributions are the ones with type hashes")
    func modernDistrosHaveTypeHashes() {
        #expect(IRBuilder.modernDistros == ROS2Distro.allCases.filter(\.supportsTypeHash).map(\.rawValue))
    }
}
