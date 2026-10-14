import Foundation
import Testing

@testable import SwiftROS2Gen

@Suite("Unresolved element types of array fields")
struct UnresolvedElementTypeTests {
    /// Writes `files` (path relative to the package root → contents) into a fresh
    /// package directory, runs `body` with it, and removes the directory afterwards.
    private static func withPackage<T>(_ files: [String: String], _ body: (URL) throws -> T) throws -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-ros2-gen-unresolved-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return try body(root)
    }

    /// Asserts that `body` throws `GeneratorError.unresolvedNestedType` for `missing_pkg/Thing`.
    private static func expectUnresolvedThing(_ body: () throws -> [GeneratedFile]) {
        do {
            _ = try body()
            Issue.record("expected GeneratorError.unresolvedNestedType")
        } catch GeneratorError.unresolvedNestedType(let pkg, let type) {
            #expect(pkg == "missing_pkg")
            #expect(type == "Thing")
        } catch {
            Issue.record("expected GeneratorError.unresolvedNestedType, got \(error)")
        }
    }

    @Test(
        "a missing package behind an array or sequence field throws unresolvedNestedType",
        arguments: [
            "missing_pkg/Thing[] things",
            "missing_pkg/Thing[3] things",
            "missing_pkg/Thing[<=3] things",
        ])
    func messageFieldThrows(field: String) throws {
        try Self.withPackage(["msg/Host.msg": "\(field)\n"]) { root in
            Self.expectUnresolvedThing {
                try Pipeline.generateMulti([
                    .init(input: PackageInput(name: "host_pkg", directory: root))
                ])
            }
        }
    }

    @Test(
        "a missing package behind an array or sequence field of a service half throws unresolvedNestedType",
        arguments: [
            "missing_pkg/Thing[] things\n---\nbool ok\n",
            "bool ok\n---\nmissing_pkg/Thing[3] things\n",
            "bool ok\n---\nmissing_pkg/Thing[<=3] things\n",
        ])
    func serviceFieldThrows(contents: String) throws {
        try Self.withPackage(["srv/Host.srv": contents]) { root in
            Self.expectUnresolvedThing {
                try Pipeline.generateMulti([
                    .init(input: PackageInput(name: "host_pkg", directory: root))
                ])
            }
        }
    }
}
