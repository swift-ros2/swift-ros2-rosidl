// swift-tools-version: 5.9

import Foundation
import PackageDescription

// swift-ros2-rosidl: the ROS 2 interface layer for Swift. CDR, the message protocols, the
// runtime interface packages and the swift-ros2-gen generator. Pure Swift with no binary
// targets, so packages that depend on it never download native frameworks.

var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
]
// swift-docc-plugin only when building documentation, so consumers do not resolve it.
if ProcessInfo.processInfo.environment["SWIFT_ROS2_DOCS_BUILD"] == "1" {
    dependencies.append(.package(url: "https://github.com/apple/swift-docc-plugin", from: "1.3.0"))
}

let package = Package(
    name: "swift-ros2-rosidl",
    platforms: [.iOS(.v16), .macOS(.v13), .macCatalyst(.v16), .visionOS(.v1)],
    products: [
        .library(name: "SwiftROS2CDR", targets: ["SwiftROS2CDR"]),
        .library(name: "SwiftROS2Messages", targets: ["SwiftROS2Messages"]),
        .library(name: "SwiftROS2Gen", targets: ["SwiftROS2Gen"]),
        .executable(name: "swift-ros2-gen", targets: ["swift-ros2-gen"]),
        .plugin(name: "SwiftROS2GenPlugin", targets: ["SwiftROS2GenPlugin"]),
    ],
    dependencies: dependencies,
    targets: [
        .target(name: "SwiftROS2CDR", path: "Sources/SwiftROS2CDR"),
        .target(
            name: "SwiftROS2Messages", dependencies: ["SwiftROS2CDR"],
            path: "Sources/SwiftROS2Messages"),
        .target(name: "SwiftROS2Gen", path: "Sources/SwiftROS2Gen"),
        .executableTarget(
            name: "swift-ros2-gen",
            dependencies: [
                "SwiftROS2Gen",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/swift-ros2-gen"),
        .plugin(
            name: "SwiftROS2GenPlugin", capability: .buildTool(),
            dependencies: [.target(name: "swift-ros2-gen")],
            path: "Plugins/SwiftROS2GenPlugin"),
        .executableTarget(
            name: "PluginSmoke", dependencies: ["SwiftROS2CDR", "SwiftROS2Messages"],
            path: "Sources/Examples/PluginSmoke", exclude: ["msg"],
            plugins: [.plugin(name: "SwiftROS2GenPlugin")]),
        .testTarget(
            name: "SwiftROS2CDRTests", dependencies: ["SwiftROS2CDR", "SwiftROS2Messages"],
            path: "Tests/SwiftROS2CDRTests"),
        .testTarget(
            name: "SwiftROS2MessagesTests", dependencies: ["SwiftROS2Messages"],
            path: "Tests/SwiftROS2MessagesTests"),
        .testTarget(
            name: "SwiftROS2GenTests", dependencies: ["SwiftROS2Gen"],
            path: "Tests/SwiftROS2GenTests", resources: [.copy("Resources")]),
        .testTarget(
            name: "SwiftROS2GenPluginTests", dependencies: [],
            path: "Tests/SwiftROS2GenPluginTests"),
    ]
)
