import Testing

@testable import SwiftROS2Gen

@Suite("Struct naming")
struct NamingTests {
    @Test(
        "ROS names equal to Swift standard-library types get Msg",
        arguments: ["Duration", "Range", "Clock", "Bool", "String", "Empty", "Float64"])
    func collisionsGetSuffix(name: String) {
        #expect(SwiftEmitter.swiftStructName(typeName: name) == name + "Msg")
    }

    @Test("other names stay bare", arguments: ["Time", "Image", "Path", "Header", "UUID"])
    func othersStayBare(name: String) {
        #expect(SwiftEmitter.swiftStructName(typeName: name) == name)
    }
}
