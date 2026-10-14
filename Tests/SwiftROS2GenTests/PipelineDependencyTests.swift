import Foundation
import Testing

@testable import SwiftROS2Gen

@Suite("Dependency-only inputs")
struct PipelineDependencyTests {
    private func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources/IDL"))
    }

    @Test("dependency packages resolve references but emit nothing")
    func dependencyIsNotEmitted() throws {
        let files = try Pipeline.generateMulti([
            .init(input: PackageInput(name: "std_msgs", directory: try fixture("std_msgs_with_header"))),
            .init(
                input: PackageInput(name: "builtin_interfaces", directory: try fixture("builtin_interfaces")),
                emit: false),
        ])
        #expect(files.map(\.relativePath).allSatisfy { $0.hasPrefix("StdMsgs/") })
        let header = try #require(files.first { $0.relativePath == "StdMsgs/Header.swift" })
        #expect(header.contents.contains("\nimport BuiltinInterfaces\n"))
    }

    @Test("the hash of an emitted type is unchanged when its dependency is dependency-only")
    func hashMatchesFullGeneration() throws {
        let both = try Pipeline.generateMulti([
            .init(input: PackageInput(name: "std_msgs", directory: try fixture("std_msgs_with_header"))),
            .init(input: PackageInput(name: "builtin_interfaces", directory: try fixture("builtin_interfaces"))),
        ])
        let depOnly = try Pipeline.generateMulti([
            .init(input: PackageInput(name: "std_msgs", directory: try fixture("std_msgs_with_header"))),
            .init(
                input: PackageInput(name: "builtin_interfaces", directory: try fixture("builtin_interfaces")),
                emit: false),
        ])
        let a = try #require(both.first { $0.relativePath == "StdMsgs/Header.swift" })
        let b = try #require(depOnly.first { $0.relativePath == "StdMsgs/Header.swift" })
        #expect(a.contents == b.contents)
    }

    @Test("a package cannot be both an input and a dependency")
    func conflictingRolesRejected() throws {
        #expect(throws: GeneratorError.self) {
            _ = try Pipeline.generateMulti([
                .init(input: PackageInput(name: "builtin_interfaces", directory: try fixture("builtin_interfaces"))),
                .init(
                    input: PackageInput(
                        name: "builtin_interfaces", directory: try fixture("builtin_interfaces"), distro: "humble"),
                    emit: false),
            ])
        }
    }

    @Test("verify plans skip dependency packages")
    func verifyPlanSkipsDependencies() throws {
        let plan = try Pipeline.buildVerifyPlan([
            .init(input: PackageInput(name: "std_msgs", directory: try fixture("std_msgs_with_header"))),
            .init(
                input: PackageInput(name: "builtin_interfaces", directory: try fixture("builtin_interfaces")),
                emit: false),
        ])
        #expect(!plan.isEmpty)
        #expect(plan.allSatisfy { $0.package == "std_msgs" })
    }
}
