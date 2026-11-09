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
        try self.init(packages: [package: filesByDistro])
    }

    /// Several packages, each with its own files per distribution (and so its own set of
    /// distributions), all emitted.
    init(packages: [String: [String: [String: String]]]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "swift-ros2-gen-multi-distro-\(UUID().uuidString)", isDirectory: true)
        var runs: [Pipeline.PackageRun] = []
        for (package, filesByDistro) in packages.sorted(by: { $0.key < $1.key }) {
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

    /// `fixture_msgs/action/Merge`, whose `.action` differs in every distribution like
    /// `nav2_msgs/action/NavigateToPose`, with `std_msgs/Empty` for each distribution:
    /// - result: `std_msgs/Empty result` on Humble, `error_code` and `error_msg` from Jazzy on,
    ///   with the constant `NONE`, to which Kilted adds `TIMEOUT` and Lyrical `GOAL_REJECTED`
    ///   (written before `TIMEOUT` in its file);
    /// - goal: `order`, plus `behavior` from Kilted on;
    /// - feedback: `progress`, plus `tracking_error` from Lyrical on.
    static let merging: [String: [String: [String: String]]] = {
        let actions = [
            "humble": "int32 order\n---\nstd_msgs/Empty result\n---\nfloat32 progress\n",
            "jazzy": "int32 order\n---\nuint16 NONE=0\nuint16 error_code\nstring error_msg\n---\nfloat32 progress\n",
            "kilted": "int32 order\nstring behavior\n---\nuint16 NONE=0\nuint16 TIMEOUT=9003\n"
                + "uint16 error_code\nstring error_msg\n---\nfloat32 progress\n",
            "lyrical": "int32 order\nstring behavior\n---\nuint16 NONE=0\nuint16 GOAL_REJECTED=1\nuint16 TIMEOUT=9003\n"
                + "uint16 error_code\nstring error_msg\n---\nfloat32 progress\nfloat32 tracking_error\n",
        ]
        return [
            "fixture_msgs": actions.mapValues { ["action/Merge.action": $0] },
            "std_msgs": actions.mapValues { _ in ["msg/Empty.msg": "\n"] },
        ]
    }()

    /// `fixture_msgs/srv/Probe`, whose `.srv` differs in every distribution like
    /// `nav2_msgs/srv/IsPathValid`:
    /// - request: `int32 target`, plus `string legacy_mode` on Humble only and
    ///   `float64 tolerance 0.5` from Kilted on;
    /// - response: `uint8 status`, with the constant `OK` from Kilted on, to which Lyrical adds
    ///   `BUSY` and the field `bool success` before `status`.
    static let probing: [String: [String: String]] = [
        "humble": ["srv/Probe.srv": "int32 target\nstring legacy_mode\n---\nuint8 status\n"],
        "jazzy": ["srv/Probe.srv": "int32 target\n---\nuint8 status\n"],
        "kilted": ["srv/Probe.srv": "int32 target\nfloat64 tolerance 0.5\n---\nuint8 OK=0\nuint8 status\n"],
        "lyrical": [
            "srv/Probe.srv": "int32 target\nfloat64 tolerance 0.5\n---\nuint8 OK=0\nuint8 BUSY=2\nbool success\n"
                + "uint8 status\n"
        ],
    ]

    /// `fixture_msgs/action/Shift` on Jazzy and Lyrical, two of whose parts have no fields in
    /// one of them: the goal has `int32 order` on Jazzy and no fields on Lyrical, the feedback no
    /// fields on Jazzy and `float32 x` on Lyrical. The result is `int32 code` on both.
    static let shifting: [String: [String: String]] = [
        "jazzy": ["action/Shift.action": "int32 order\n---\nint32 code\n---\n"],
        "lyrical": ["action/Shift.action": "---\nint32 code\n---\nfloat32 x\n"],
    ]

    /// `fixture_msgs/msg/Grow`: `int32 old` on Humble, no fields on Jazzy and Kilted, and
    /// `float64 x` on Lyrical.
    static let growing: [String: [String: String]] = [
        "humble": ["msg/Grow.msg": "int32 old\n"], "jazzy": ["msg/Grow.msg": "\n"],
        "kilted": ["msg/Grow.msg": "\n"], "lyrical": ["msg/Grow.msg": "float64 x\n"],
    ]
}
