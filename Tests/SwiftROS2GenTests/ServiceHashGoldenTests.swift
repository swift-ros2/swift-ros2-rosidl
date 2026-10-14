import Foundation
import Testing

@testable import SwiftROS2Gen

/// Service-level and action-service RIHS01 hashes against the `type_hashes` of the
/// rosidl-generated type description JSON (`/opt/ros/<distro>/share/<pkg>/<kind>/<Type>.json`)
/// shipped with Jazzy, Kilted and Lyrical. These hashes are identical in all three; rmw_zenoh_cpp
/// keys services by them.
@Suite("RIHS01 service-level hashes — golden")
struct ServiceHashGoldenTests {
    /// Ground truth, identical on Jazzy, Kilted and Lyrical.
    static let upstream: [String: String] = [
        "std_srvs/srv/Trigger": "RIHS01_eeff2cd6fa5ad9d27cdf4dec64818317839b62f212a91e6b5304b634b2062c5f",
        "std_srvs/srv/Trigger_Event": "RIHS01_ec4a1d26b0575e61906890342aba9523a2360e9845857c5590fa6e23bc39e1c2",
        "std_srvs/srv/SetBool": "RIHS01_abe9e4bb6b41b40e6789712c00ec8871923e089af3f667a79992a428cff2da0a",
        "std_srvs/srv/SetBool_Event": "RIHS01_3c4c20015afb4303eafd347b1d6a786f171a89c814726961a9593ef10df878cf",
        "std_srvs/srv/Empty": "RIHS01_5888399dedec5ccc85ea6451949fd2c9f97bfdf963f9a588821639fcd31b5d19",
        "std_srvs/srv/Empty_Event": "RIHS01_66fa7fcfb5f2bf04b9a8a55603318c5c402edfc4bd56bb0ed7b602990c29305a",
        "example_interfaces/srv/AddTwoInts":
            "RIHS01_e118de6bf5eeb66a2491b5bda11202e7b68f198d6f67922cf30364858239c81a",
        "example_interfaces/srv/AddTwoInts_Event":
            "RIHS01_32c1d140259c71e5c355115942bcb31df98b4330e4d906b1b75ccb1c9b3ce6c8",
        "example_interfaces/action/Fibonacci":
            "RIHS01_9508051da1ea4658de144b09bd0690ff3de52104683d847aed764d2915906f51",
        "example_interfaces/action/Fibonacci_SendGoal":
            "RIHS01_d1a57fb2a4afe8c21e34fb10db206f16ce6729b28531141472df92277c55b557",
        "example_interfaces/action/Fibonacci_SendGoal_Event":
            "RIHS01_d5e5b312dbf847307b0e876c2ecc9d80258e95b0d17f8f7bfc581c4a29c83484",
        "example_interfaces/action/Fibonacci_GetResult":
            "RIHS01_1b0de0d5d29dc955d92f546706568428632771db13ec84c15ec1c1a59f424a57",
        "example_interfaces/action/Fibonacci_GetResult_Event":
            "RIHS01_ac4e9cdb954c2e192c9f0753d46f59ab6f0101d5fb5b9542fd8ab2906e40c4d9",
    ]

    static let modernDistros = ["jazzy", "kilted", "lyrical"]

    /// `Resources/IDL/<package>` in the test bundle.
    static func packageDir(_ package: String) throws -> URL {
        try #require(
            Bundle.module.url(forResource: package, withExtension: nil, subdirectory: "Resources/IDL"))
    }

    /// One run per package, labelled `distro`.
    static func runs(_ packages: [(String, Set<String>?)], distro: String) throws -> [Pipeline.PackageRun] {
        try packages.map { name, types in
            .init(
                input: PackageInput(name: name, directory: try packageDir(name), distro: distro), typesAllowList: types)
        }
    }

    static func planHashes(_ runs: [Pipeline.PackageRun]) throws -> [String: String] {
        var out: [String: String] = [:]
        for entry in try Pipeline.buildVerifyPlan(runs) { out[entry.rosTypeName] = entry.expectedHash }
        return out
    }

    @Test("ServiceEventInfo hashes like service_msgs/msg/ServiceEventInfo")
    func serviceEventInfo() {
        let registry = [ServiceDescription.time.rosTypeName: ServiceDescription.time]
        #expect(
            RIHS01.hash(ServiceDescription.serviceEventInfo, registry: registry)
                == "RIHS01_41bcbbe07a75c9b52bc96bfd5c24d7f0fc0a08c0cb7921b3373c5732345a6f45")
    }

    @Test(
        "std_srvs and example_interfaces services: the verify plan carries the upstream hashes",
        arguments: modernDistros)
    func servicePlan(distro: String) throws {
        let hashes = try Self.planHashes(
            try Self.runs([("std_srvs", nil), ("example_interfaces", ["AddTwoInts"])], distro: distro))
        for name in [
            "std_srvs/srv/Trigger", "std_srvs/srv/Trigger_Event", "std_srvs/srv/SetBool",
            "std_srvs/srv/SetBool_Event", "std_srvs/srv/Empty", "std_srvs/srv/Empty_Event",
            "example_interfaces/srv/AddTwoInts", "example_interfaces/srv/AddTwoInts_Event",
        ] {
            #expect(hashes[name] == Self.upstream[name], "\(name) (\(distro))")
        }
    }

    @Test("Fibonacci action: the verify plan carries the upstream action and service hashes", arguments: modernDistros)
    func actionPlan(distro: String) throws {
        let hashes = try Self.planHashes(
            try Self.runs(
                [
                    ("example_interfaces", ["Fibonacci"]), ("unique_identifier_msgs", nil),
                    ("builtin_interfaces", ["Time"]),
                ],
                distro: distro))
        for name in [
            "example_interfaces/action/Fibonacci", "example_interfaces/action/Fibonacci_SendGoal",
            "example_interfaces/action/Fibonacci_SendGoal_Event", "example_interfaces/action/Fibonacci_GetResult",
            "example_interfaces/action/Fibonacci_GetResult_Event",
        ] {
            #expect(hashes[name] == Self.upstream[name], "\(name) (\(distro))")
        }
    }

    @Test("Humble has no type hashes, so the verify plan has no service entries")
    func humblePlan() throws {
        let plan = try Pipeline.buildVerifyPlan(try Self.runs([("std_srvs", nil)], distro: "humble"))
        #expect(plan.isEmpty)
    }

    @Test("the service umbrella's typeInfo carries the service-level hash")
    func umbrellaEmitsServiceHash() throws {
        let files = try Pipeline.generateMulti(
            try Self.runs([("std_srvs", ["Trigger"]), ("example_interfaces", ["AddTwoInts"])], distro: "lyrical"))
        let trigger = try #require(files.first { $0.relativePath == "StdSrvs/TriggerSrv.swift" })
        #expect(trigger.contents.contains("serviceTypeHash: \"\(Self.upstream["std_srvs/srv/Trigger"]!)\""))
        let addTwoInts = try #require(files.first { $0.relativePath == "ExampleInterfaces/AddTwoIntsSrv.swift" })
        #expect(
            addTwoInts.contents.contains(
                "serviceTypeHash: \"\(Self.upstream["example_interfaces/srv/AddTwoInts"]!)\""))
    }

    @Test("the action's typeInfo carries the SendGoal and GetResult service hashes")
    func actionEmitsServiceHashes() throws {
        let files = try Pipeline.generateMulti(
            try Self.runs(
                [
                    ("example_interfaces", ["Fibonacci"]), ("unique_identifier_msgs", nil),
                    ("builtin_interfaces", ["Time"]),
                ],
                distro: "jazzy"))
        let action = try #require(files.first { $0.relativePath == "ExampleInterfaces/FibonacciAction.swift" })
        #expect(
            action.contents.contains(
                "sendGoalServiceTypeHash: \"\(Self.upstream["example_interfaces/action/Fibonacci_SendGoal"]!)\""))
        #expect(
            action.contents.contains(
                "getResultServiceTypeHash: \"\(Self.upstream["example_interfaces/action/Fibonacci_GetResult"]!)\""))
    }
}
