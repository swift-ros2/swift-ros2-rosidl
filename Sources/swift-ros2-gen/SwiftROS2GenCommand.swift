import ArgumentParser
import Foundation
import SwiftROS2Gen

@main
struct SwiftROS2GenCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swift-ros2-gen",
        abstract: "Generate Swift ROS2Message conformances from ROS 2 IDL"
    )

    @Option(
        name: .long,
        help:
            "<package_name>=<directory>@<distro>. Repeatable. Pass the same package name with several distros (e.g. @humble and @jazzy) to produce one distro-conditional Swift file per type."
    )
    var input: [String] = []

    @Option(
        name: .long,
        help:
            "<package_name>=<directory>@<distro>. Repeatable. A package whose types are referenced and hashed but not emitted (they live in another Swift module). Same format as --input."
    )
    var dependency: [String] = []

    @Option(
        name: .long,
        help:
            "Output directory root (per-package subdirectories are created underneath). Required for emit mode; ignored when --verify-hashes is set."
    )
    var output: String = ""

    @Option(
        name: .long,
        help:
            "Comma-separated allow-list of types to emit. When omitted, every supported type in the package is emitted."
    )
    var types: String?

    @Flag(name: .long, help: "Print what would be written; do not touch the filesystem.")
    var dryRun: Bool = false

    @Option(
        name: .long,
        help: """
            <package_name>=<Module>. Repeatable. Swift module that holds a ROS package's types; defaults to the \
            package name in PascalCase (geometry_msgs → GeometryMsgs). Generated files import the module of every \
            package they reference except their own.
            """
    )
    var module: [String] = []

    @Option(
        name: .long,
        help:
            "Also write CDR oracle sample sources (one file per package plus OracleSamples.swift) to this directory. Emit mode only."
    )
    var emitOracleSamples: String?

    @Option(
        name: .long,
        help: """
            Compare each generated type's RIHS01 hash against the oracle running inside the named Docker image \
            (e.g. 'osrf/ros:jazzy-desktop'). Implies --dry-run; exits non-zero on mismatch.
            """
    )
    var verifyHashes: String?

    @Option(
        name: .long,
        help: """
            Comma-separated distro allow-list for --verify-hashes (default: all distros derived from --input \
            except 'humble', which has no rosidl type-hash JSON). Each distro must match the tag the Docker image \
            is pulled from (e.g. 'jazzy,kilted,lyrical,rolling').
            """
    )
    var distros: String?

    @Flag(
        name: .long,
        help: """
            On hash-mismatch, dump the canonical oracle JSON plus a summary of the expected vs. observed RIHS01 \
            under /tmp/swift-ros2-gen-diagnose/. Useful for finding the IR-builder or RIHS01 implementation drift.
            """
    )
    var diagnose: Bool = false

    func validate() throws {
        // Reject whitespace, quotes and newlines in a --module value before it is spliced into
        // emitted Swift `import` lines.
        for raw in module {
            let parts = raw.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty, ModuleIdentifier.isValid(parts[1]) else {
                throw ValidationError("invalid --module '\(raw)' — expected <package_name>=<Module>")
            }
        }
    }

    /// The `--module` overrides as a ROS package → Swift module map.
    var moduleNames: ModuleNames {
        var names: ModuleNames = [:]
        for raw in module {
            let parts = raw.split(separator: "=", maxSplits: 1).map(String.init)
            names[parts[0]] = parts[1]
        }
        return names
    }

    func run() throws {
        if let image = verifyHashes {
            try runVerifyMode(image: image)
            return
        }
        try runEmitMode()
    }

    func runEmitMode() throws {
        guard !output.isEmpty else {
            throw ValidationError("--output is required in emit mode (omit only with --verify-hashes)")
        }
        let outputRoot = URL(fileURLWithPath: output, isDirectory: true)
        let allowList: Set<String>? = types.map {
            Set($0.split(separator: ",").map(String.init))
        }
        var runs: [Pipeline.PackageRun] = []
        for raw in input {
            let pkg = try parseInput(raw)
            // Phase 4: every distro is consumed. When the same package name
            // appears twice (e.g. once @humble and once @jazzy), the
            // pipeline merges them into a single distro-conditional IR.
            runs.append(
                .init(
                    input: PackageInput(
                        name: pkg.packageName,
                        directory: pkg.directory,
                        distro: pkg.distro
                    ),
                    typesAllowList: allowList
                ))
        }
        for raw in dependency {
            let pkg = try parseInput(raw, option: "--dependency")
            runs.append(
                .init(
                    input: PackageInput(name: pkg.packageName, directory: pkg.directory, distro: pkg.distro),
                    typesAllowList: nil, emit: false))
        }
        let files: [GeneratedFile]
        var oracleSamples: [GeneratedFile] = []
        do {
            files = try Pipeline.generateMulti(runs, moduleNames: moduleNames)
            if emitOracleSamples != nil {
                oracleSamples = try Pipeline.generateOracleSamples(runs, moduleNames: moduleNames)
            }
        } catch let err as GeneratorError {
            FileHandle.standardError.write(Data("error: \(err)\n".utf8))
            throw ExitCode.failure
        }
        try write(files, to: outputRoot)
        if let samplesDirectory = emitOracleSamples {
            try write(oracleSamples, to: URL(fileURLWithPath: samplesDirectory, isDirectory: true))
        }
    }

    /// Writes `files` under `root`, or prints what would be written with `--dry-run`.
    func write(_ files: [GeneratedFile], to root: URL) throws {
        for file in files {
            let absolute = root.appendingPathComponent(file.relativePath)
            if dryRun {
                FileHandle.standardOutput.write(
                    Data("WRITE \(absolute.path) (\(file.contents.utf8.count) bytes)\n".utf8))
            } else {
                try FileManager.default.createDirectory(
                    at: absolute.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try file.contents.write(to: absolute, atomically: true, encoding: .utf8)
            }
        }
    }

    func runVerifyMode(image: String) throws {
        let allowedDistros: Set<String>? = distros.map {
            Set($0.split(separator: ",").map(String.init))
        }
        let allowList: Set<String>? = types.map {
            Set($0.split(separator: ",").map(String.init))
        }
        var runs: [Pipeline.PackageRun] = []
        for raw in input {
            let pkg = try parseInput(raw)
            // Skip inputs whose distro is excluded by the allow-list. We
            // still parse every other distro since cross-package nested
            // references (e.g. sensor_msgs/Imu -> std_msgs/Header) must
            // resolve in `Pipeline.buildVerifyPlan`'s registry.
            if let allowed = allowedDistros, !allowed.contains(pkg.distro) { continue }
            runs.append(
                .init(
                    input: PackageInput(
                        name: pkg.packageName,
                        directory: pkg.directory,
                        distro: pkg.distro
                    ),
                    typesAllowList: allowList
                ))
        }
        for raw in dependency {
            let pkg = try parseInput(raw, option: "--dependency")
            runs.append(
                .init(
                    input: PackageInput(name: pkg.packageName, directory: pkg.directory, distro: pkg.distro),
                    typesAllowList: nil, emit: false))
        }
        let plan: [VerifyPlanEntry]
        do {
            plan = try Pipeline.buildVerifyPlan(runs, distros: allowedDistros)
        } catch let err as GeneratorError {
            FileHandle.standardError.write(Data("error: \(err)\n".utf8))
            throw ExitCode.failure
        }
        // An empty plan means the input filters (--input paths, --types,
        // --distros) selected zero IRs. That is almost
        // always a misconfiguration — e.g. a typo'd vendor path on a
        // case-sensitive Linux runner that resolves to nothing — which
        // would otherwise be reported as `mismatches=0 missing=0` and pass
        // silently. Surface it as a hard error so CI catches the typo.
        if plan.isEmpty {
            FileHandle.standardError.write(
                Data(
                    "error: --verify-hashes selected 0 types — check --input paths, --types, --distros\n"
                        .utf8))
            throw ExitCode.failure
        }
        let verifier = HashVerifier(
            oracle: OracleClient(dockerImage: image),
            diagnose: diagnose
        )
        let report: HashVerifier.Report
        do {
            report = try verifier.verifyAll(plan)
        } catch let err as OracleClient.OracleError {
            FileHandle.standardError.write(Data("hash-oracle: \(err)\n".utf8))
            throw ExitCode.failure
        }
        FileHandle.standardOutput.write(Data(report.summary.utf8))
        if !report.mismatches.isEmpty || !report.missingFromOracle.isEmpty {
            throw ExitCode.failure
        }
    }

    struct ParsedInput {
        let packageName: String
        let directory: URL
        let distro: String
    }

    func parseInput(_ raw: String, option: String = "--input") throws -> ParsedInput {
        do {
            let parsed = try PackageInput.parse(raw, option: option)
            return ParsedInput(packageName: parsed.name, directory: parsed.directory, distro: parsed.distro)
        } catch let error as PackageInputFormatError {
            throw ValidationError(error.description)
        }
    }
}
