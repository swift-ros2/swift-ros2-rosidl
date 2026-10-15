import Foundation

@testable import SwiftROS2Gen

/// A throwaway `fixture_msgs` package on disk, holding the given IDL files by relative path.
enum TempIDLPackage {
    static func make(_ files: [String: String]) throws -> PackageInput {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dir = root.appendingPathComponent("fixture_msgs")
        for (path, contents) in files {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return PackageInput(name: "fixture_msgs", directory: dir)
    }

    static func remove(_ input: PackageInput) {
        try? FileManager.default.removeItem(at: input.directory.deletingLastPathComponent())
    }
}
