import Foundation
import Testing

@testable import SwiftROS2Gen

/// A package read for several distributions: one directory per distribution under a throwaway
/// root, holding the given IDL files by relative path, plus `unique_identifier_msgs` and
/// `builtin_interfaces` from `Resources/IDL` as dependencies (action wrappers reference them).
struct MultiDistroFixture {
    let root: URL
    let runs: [Pipeline.PackageRun]

    init(_ filesByDistro: [String: [String: String]], package: String = "fixture_msgs") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "swift-ros2-gen-multi-distro-\(UUID().uuidString)", isDirectory: true)
        var runs: [Pipeline.PackageRun] = []
        for distro in IRBuilder.distroOrder where filesByDistro[distro] != nil {
            let dir = root.appendingPathComponent("\(distro)/\(package)", isDirectory: true)
            for (path, contents) in filesByDistro[distro]! {
                let url = dir.appendingPathComponent(path)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try contents.write(to: url, atomically: true, encoding: .utf8)
            }
            runs.append(Pipeline.PackageRun(input: PackageInput(name: package, directory: dir, distro: distro)))
        }
        for name in ["unique_identifier_msgs", "builtin_interfaces"] {
            let dir = try #require(
                Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources/IDL"))
            runs.append(Pipeline.PackageRun(input: PackageInput(name: name, directory: dir), emit: false))
        }
        self.runs = runs
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    /// `Pipeline.generateMulti` output, by relative path.
    func generate() throws -> [String: String] {
        Dictionary(uniqueKeysWithValues: try Pipeline.generateMulti(runs).map { ($0.relativePath, $0.contents) })
    }

    /// The `RIHS01_…` hashes in `source`, in order of appearance.
    static func hashes(in source: String) -> [String] {
        var out: [String] = []
        var rest = source[...]
        while let range = rest.range(of: "RIHS01_") {
            let hex = rest[range.upperBound...].prefix { $0.isHexDigit }
            out.append("RIHS01_" + hex)
            rest = rest[range.upperBound...]
        }
        return out
    }

    /// `fixture_msgs/msg/ModernVarying` in Humble, Jazzy, Kilted and Lyrical, with a field for
    /// every kind of distribution bound, and `fixture_msgs/action/ModernVarying`, whose goal
    /// holds one.
    static let modernVarying: [String: [String: String]] = {
        let action = "ModernVarying value\n---\nint32 code\n---\nfloat32 progress\n"
        let messages = [
            "humble": "int32 a\nstring until_lyrical\n",
            "jazzy": "int32 a\nfloat32 since_jazzy\nstring until_lyrical\n",
            "kilted": "int32 a\nfloat32 since_jazzy\nuint8 kilted_only 7\nstring until_lyrical\n",
            "lyrical": "int32 a\nfloat32 since_jazzy\nfloat64 since_lyrical\n",
        ]
        return messages.mapValues { ["msg/ModernVarying.msg": $0, "action/ModernVarying.action": action] }
    }()
}
