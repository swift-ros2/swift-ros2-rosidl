import Foundation

/// Identifies a ROS 2 package directory that the generator should process.
public struct PackageInput: Sendable {
    public let name: String  // "std_msgs"
    public let directory: URL  // <idl-root>/std_msgs
    /// ROS 2 distro this directory represents (e.g. "humble", "jazzy"). The
    /// pipeline groups inputs that share `name` across distros and merges
    /// their per-distro IDLs into a single distro-conditional IR.
    public let distro: String

    public init(name: String, directory: URL, distro: String = "jazzy") {
        self.name = name
        self.directory = directory
        self.distro = distro
    }
}

/// Errors that the ``Pipeline`` surfaces when generation cannot proceed.
public enum GeneratorError: Error, CustomStringConvertible {
    case packageDirectoryMissing(URL)
    case parse(ParseError)
    case unresolvedNestedType(package: String, typeName: String)
    case invalidExtraImport(String)
    /// A package is passed both as an emitted input and as a dependency-only input.
    case conflictingPackageRoles(String)
    /// A field exists in only some modern distributions (Jazzy and later), which generated
    /// types cannot express.
    case modernDistroDivergence(type: String, field: String, presentIn: [String], missingFrom: [String])

    public var description: String {
        switch self {
        case .packageDirectoryMissing(let url):
            return "package directory missing: \(url.path)"
        case .parse(let error):
            return error.description
        case .unresolvedNestedType(let pkg, let type):
            return
                "unresolved nested type '\(pkg)/\(type)' — pass --input or --dependency for '\(pkg)' on the same CLI invocation"
        case .invalidExtraImport(let value):
            return
                "invalid --extra-import '\(value)' — expected a Swift module identifier (e.g. 'SwiftROS2Messages' or 'My.Nested.Module')"
        case .conflictingPackageRoles(let name):
            return "package '\(name)' is passed both as --input and as --dependency"
        case .modernDistroDivergence(let type, let field, let presentIn, let missingFrom):
            return
                "\(type): field '\(field)' exists in \(presentIn) but not in \(missingFrom) — generated types support one modern shape (Jazzy and later); differences among modern distributions are not supported"
        }
    }
}

/// Module-name validation shared by the CLI and the `Pipeline` so untrusted
/// user input cannot be spliced verbatim into emitted `import` lines. A valid
/// module identifier matches `[A-Za-z_][A-Za-z0-9_]*`, optionally dotted for
/// nested modules (e.g. `Foo.Bar`). Whitespace, quotes, and newlines are all
/// rejected.
public enum ModuleIdentifier {
    /// Returns `true` when `value` is a syntactically valid Swift module
    /// identifier (single segment or dotted). Empty strings are rejected.
    public static func isValid(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let segments = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !segments.isEmpty else { return false }
        for segment in segments {
            if segment.isEmpty { return false }
            let scalars = segment.unicodeScalars
            guard let first = scalars.first else { return false }
            let isHeadValid =
                (first.value >= 0x41 && first.value <= 0x5A)  // A-Z
                || (first.value >= 0x61 && first.value <= 0x7A)  // a-z
                || first == "_"
            if !isHeadValid { return false }
            for scalar in scalars.dropFirst() {
                let isTailValid =
                    (scalar.value >= 0x41 && scalar.value <= 0x5A)  // A-Z
                    || (scalar.value >= 0x61 && scalar.value <= 0x7A)  // a-z
                    || (scalar.value >= 0x30 && scalar.value <= 0x39)  // 0-9
                    || scalar == "_"
                if !isTailValid { return false }
            }
        }
        return true
    }

    /// Throws ``GeneratorError/invalidExtraImport(_:)`` for any entry that
    /// isn't a valid module identifier. Called by the `Pipeline` boundary so
    /// `extraImports` can be trusted by the emitter even when the CLI
    /// validation layer is bypassed (e.g. when `Pipeline` is invoked directly
    /// from a unit test).
    public static func validateAll(_ values: [String]) throws {
        for value in values where !isValid(value) {
            throw GeneratorError.invalidExtraImport(value)
        }
    }
}

/// Maps `<pkg>/msg/<TypeName>` → preferred Swift struct name. Lets the emitter use
/// historic names like `UniqueIdentifierUUID` (which the rest of the codebase
/// already imports) instead of the default collision-rule output.
public typealias SwiftNameOverrides = [String: String]

/// A single Swift source file produced by the generator.
public struct GeneratedFile: Equatable, Sendable {
    public let relativePath: String  // "StdMsgs/BoolMsg.swift"
    public let contents: String

    public init(relativePath: String, contents: String) {
        self.relativePath = relativePath
        self.contents = contents
    }
}

/// Orchestrates parsing, IR building, hashing, and emission for a ROS 2 package.
public enum Pipeline {
    /// Process a single jazzy-distro package and return generated files.
    /// Phase 1: only primitive-typed messages are accepted; everything else
    /// surfaces as a `GeneratorError.parse(...)`.
    ///
    /// - Parameters:
    ///   - input: Package name and directory containing the `msg/` subdirectory.
    ///   - typesAllowList: When non-nil, only `.msg` files whose stem (e.g. `"Bool"`)
    ///     appear in this set are processed. Files outside the allow-list are silently
    ///     skipped before reaching the parser, keeping Phase 1 functional against real
    ///     vendor directories that contain unsupported message types.
    public static func generate(
        for input: PackageInput,
        typesAllowList: Set<String>? = nil,
        extraImports: [String] = [],
        moduleNames: ModuleNames = [:]
    ) throws -> [GeneratedFile] {
        try ModuleIdentifier.validateAll(extraImports)
        let msgDir = input.directory.appendingPathComponent("msg", isDirectory: true)
        var isDir: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: msgDir.path, isDirectory: &isDir),
            isDir.boolValue
        else {
            throw GeneratorError.packageDirectoryMissing(msgDir)
        }
        let entries = try FileManager.default.contentsOfDirectory(
            at: msgDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let msgFiles =
            entries
            .filter { $0.pathExtension == "msg" }
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        var results: [GeneratedFile] = []
        for fileURL in msgFiles {
            let typeName = fileURL.deletingPathExtension().lastPathComponent
            // Apply allow-list at parse boundary: skip files not in the allow-list.
            if let allowList = typesAllowList, !allowList.contains(typeName) {
                continue
            }
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            let label = "\(input.name)/msg/\(typeName).msg"
            do {
                let idl = try Parser.parseMessage(
                    source: contents,
                    file: label,
                    package: input.name,
                    typeName: typeName
                )
                let ir0 = IRBuilder.build(jazzy: idl)
                let hash = RIHS01.hash(ir0)
                let ir = MessageIR(
                    package: ir0.package,
                    typeName: ir0.typeName,
                    kind: ir0.kind,
                    fields: ir0.fields,
                    constants: ir0.constants,
                    perDistroHashes: ["jazzy": hash]
                )
                let key = "\(ir.package)/msg/\(ir.typeName)"
                let nameOverride = Pipeline.defaultSwiftNameOverrides[key]
                let isNested = Pipeline.defaultNestedOnlyTypes.contains(key)
                let swift = SwiftEmitter.emit(
                    ir,
                    sourceLabel: label,
                    isNested: isNested,
                    structNameOverride: nameOverride,
                    nestedNameOverrides: Pipeline.defaultSwiftNameOverrides,
                    extraImports: extraImports,
                    moduleNames: moduleNames
                )
                let pascalPackage = pascal(input.name)
                let structName = nameOverride ?? SwiftEmitter.swiftStructName(typeName: typeName)
                results.append(
                    GeneratedFile(
                        relativePath: "\(pascalPackage)/\(structName).swift",
                        contents: swift
                    ))
            } catch let err as ParseError {
                throw GeneratorError.parse(err)
            }
        }
        return results
    }

    static func pascal(_ snake: String) -> String {
        snake.split(separator: "_").map {
            $0.prefix(1).uppercased() + $0.dropFirst().lowercased()
        }.joined()
    }
}

extension Pipeline {
    /// Per-type Swift struct-name overrides applied during emission. Keyed by
    /// `<package>/msg/<TypeName>` (the ROS canonical name). Emitter callers receive
    /// this same map as `nestedNameOverrides` so cross-package references resolve to
    /// the override value instead of the default ``SwiftEmitter/swiftStructName(typeName:)``.
    public static let defaultSwiftNameOverrides: SwiftNameOverrides = [
        "unique_identifier_msgs/msg/UUID": "UniqueIdentifierUUID"
    ]

    /// `<package>/msg/<TypeName>` set of types that emit as nested-only (CDRCodable,
    /// no `typeInfo`). These types are embedded as fields inside other messages and
    /// are never advertised at the topic level.
    ///
    /// NOTE: Phase 2 already emitted `BuiltinInterfaces/Time`, `GeometryMsgs/*`,
    /// and `StdMsgs/Header` as full `ROS2Message` types. Marking them nested-only
    /// here would silently regenerate them with a different conformance the next
    /// time anyone runs the CLI against those packages, breaking every existing
    /// caller. Keep this set restricted to the Phase 3 newcomers.
    public static let defaultNestedOnlyTypes: Set<String> = [
        "unique_identifier_msgs/msg/UUID",
        "action_msgs/msg/GoalInfo",
        "action_msgs/msg/GoalStatus",
    ]

    public struct PackageRun: Sendable {
        public let input: PackageInput
        public let typesAllowList: Set<String>?
        /// `false` for a dependency-only package: parsed, resolved and hashed, never emitted.
        public let emit: Bool

        public init(input: PackageInput, typesAllowList: Set<String>? = nil, emit: Bool = true) {
            self.input = input
            self.typesAllowList = typesAllowList
            self.emit = emit
        }

        /// The run to parse: a dependency-only run ignores `--types`, so every
        /// type an emitted type may reference is in the registry.
        var parseRun: PackageRun {
            emit ? self : PackageRun(input: input, typesAllowList: nil, emit: false)
        }
    }

    /// Throws ``GeneratorError/conflictingPackageRoles(_:)`` when a package is
    /// passed both as an emitted input and as a dependency-only input.
    private static func checkPackageRoles(_ runsByPackage: [String: [PackageRun]]) throws {
        for (name, group) in runsByPackage.sorted(by: { $0.key < $1.key })
        where Set(group.map(\.emit)).count > 1 {
            throw GeneratorError.conflictingPackageRoles(name)
        }
    }

    /// Generated types model two wire shapes: legacy (Humble) and modern (every later
    /// distribution). A field present in only some modern distributions cannot be expressed,
    /// so generation stops instead of emitting one distribution's shape for all of them.
    static func validateModernAgreement(_ ir: MessageIR) throws {
        let modern = Set(ir.perDistroFieldPresence.keys).subtracting(["humble"])
        for field in ir.fields {
            guard case .onlyIn(let distros) = field.availability, distros != ["humble"] else { continue }
            let present = distros.subtracting(["humble"])
            if present != modern {
                throw GeneratorError.modernDistroDivergence(
                    type: ir.rosTypeName, field: field.ros2Name,
                    presentIn: present.sorted(), missingFrom: modern.subtracting(present).sorted())
            }
        }
    }

    /// One parsed message, service half or action part, with the distributions that have it.
    struct CollectedIR {
        let run: PackageRun
        let ir: MessageIR
        let sourceLabel: String
        /// Stem of the IDL file the type comes from (`Fibonacci` for `Fibonacci_SendGoal_Request`),
        /// which names the hash oracle's JSON file.
        let topLevelTypeName: String
        /// The distributions whose IDL has the type: the run's own distribution for a single run,
        /// and for a package read from several distributions only those whose IDL has it.
        let distros: Set<String>
    }

    /// Everything `generateMulti`, `generateOracleSamples` and `buildVerifyPlan` need before
    /// emission.
    struct Collected {
        var unresolvedIRs: [CollectedIR]
        var collectedServices: [ParsedService]
        var collectedActions: [ParsedAction]
        var registry: [String: MessageIR]
        var nameOverrides: SwiftNameOverrides
        var dependencyPackages: Set<String>
    }

    /// Parses every run, merges multi-distro packages, builds the registry and the Swift
    /// name overrides, and checks that every nested reference resolves.
    static func collect(_ runs: [PackageRun]) throws -> Collected {
        var unresolvedIRs: [CollectedIR] = []
        var collectedServices: [ParsedService] = []
        var collectedActions: [ParsedAction] = []
        // Group runs by package name; multiple runs with the same name represent
        // different distros for the same logical package.
        var runsByPackage: [String: [PackageRun]] = [:]
        var packageOrder: [String] = []
        for run in runs.map(\.parseRun) {
            if runsByPackage[run.input.name] == nil { packageOrder.append(run.input.name) }
            runsByPackage[run.input.name, default: []].append(run)
        }
        try checkPackageRoles(runsByPackage)
        let dependencyPackages = Set(runs.filter { !$0.emit }.map(\.input.name))
        for pkg in packageOrder {
            let pkgRuns = runsByPackage[pkg]!
            // Labels and the run of every entry come from the first run of the package.
            let primaryRun = pkgRuns[0]
            if pkgRuns.count == 1 {
                // Single-distro fast path (Phase 1-3 behavior preserved).
                for entry in try parsePackage(run: primaryRun) {
                    unresolvedIRs.append(
                        CollectedIR(
                            run: primaryRun, ir: entry.ir, sourceLabel: entry.sourceLabel,
                            topLevelTypeName: entry.ir.typeName, distros: entry.distros))
                }
            } else {
                // Multi-distro path: parse each run's IDLs, group by type name,
                // then merge per-distro IDLs via IRBuilder.build(perDistro:).
                for entry in try parseAndMergeMultiDistroPackage(runs: pkgRuns) {
                    try validateModernAgreement(entry.ir)
                    unresolvedIRs.append(
                        CollectedIR(
                            run: primaryRun, ir: entry.ir, sourceLabel: entry.sourceLabel,
                            topLevelTypeName: entry.ir.typeName, distros: entry.distros))
                }
            }
            // Services and actions are the union across the package's runs, each with the
            // distributions whose IDL has it. Multi-distro merging is intentionally unsupported
            // for them: one whose shape differs between distros is rejected, so we never
            // silently emit one distro's shape.
            let services = try unionAcrossDistros(
                pkgRuns, kind: .srv, parse: parseServicesIn, typeName: \.typeName)
            for (svc, distros) in services {
                let label = sourceLabelFor(run: primaryRun, typeName: svc.typeName, kind: .srv)
                for half in [svc.requestIDL, svc.responseIDL] {
                    unresolvedIRs.append(
                        CollectedIR(
                            run: primaryRun, ir: IRBuilder.build(jazzy: half, kind: .srv), sourceLabel: label,
                            topLevelTypeName: svc.typeName, distros: distros))
                }
            }
            collectedServices.append(contentsOf: services.map(\.item))

            let actions = try unionAcrossDistros(
                pkgRuns, kind: .action, parse: parseActionsIn, typeName: \.typeName)
            for (act, distros) in actions {
                let label = sourceLabelFor(run: primaryRun, typeName: act.typeName, kind: .action)
                // The user-defined Goal/Result/Feedback IRs go in the registry so wrapper
                // nested references resolve; the wrappers so the action-level hash and any
                // cross-package reference to a wrapper resolves.
                let parts = [
                    act.actionIR.goal, act.actionIR.result, act.actionIR.feedback,
                    act.actionIR.sendGoalRequest, act.actionIR.sendGoalResponse,
                    act.actionIR.getResultRequest, act.actionIR.getResultResponse,
                    act.actionIR.feedbackMessage,
                ]
                for ir in parts {
                    unresolvedIRs.append(
                        CollectedIR(
                            run: primaryRun, ir: ir, sourceLabel: label, topLevelTypeName: act.typeName,
                            distros: distros))
                }
            }
            collectedActions.append(contentsOf: actions.map(\.item))
        }
        var registry: [String: MessageIR] = [:]
        for entry in unresolvedIRs {
            registry[entry.ir.rosTypeName] = entry.ir
        }
        // Auto-generate Swift name overrides for service halves so the emitter
        // produces `CancelGoalRequest` / `CancelGoalResponse` rather than
        // `CancelGoal_Request` (which is valid Swift but matches neither
        // PascalCase nor the umbrella's typealias targets).
        var nameOverrides = Pipeline.defaultSwiftNameOverrides
        for svc in collectedServices {
            nameOverrides["\(svc.package)/srv/\(svc.typeName)_Request"] =
                "\(svc.typeName)Request"
            nameOverrides["\(svc.package)/srv/\(svc.typeName)_Response"] =
                "\(svc.typeName)Response"
        }
        try validateAllReferencesResolved(registry: registry)
        return Collected(
            unresolvedIRs: unresolvedIRs, collectedServices: collectedServices,
            collectedActions: collectedActions, registry: registry, nameOverrides: nameOverrides,
            dependencyPackages: dependencyPackages)
    }

    /// The services or actions of every run of one package, in first-seen order, each with the
    /// distributions whose IDL has it. Throws when one differs between distributions.
    private static func unionAcrossDistros<Item: Equatable>(
        _ runs: [PackageRun],
        kind: MessageKind,
        parse: (PackageRun) throws -> [Item],
        typeName: (Item) -> String
    ) throws -> [(item: Item, distros: Set<String>)] {
        var union: [(item: Item, distros: Set<String>)] = []
        var indexByName: [String: Int] = [:]
        for run in runs {
            for item in try parse(run) {
                let name = typeName(item)
                guard let index = indexByName[name] else {
                    indexByName[name] = union.count
                    union.append((item, [run.input.distro]))
                    continue
                }
                guard union[index].item == item else {
                    let noun = kind == .srv ? "service" : "action"
                    throw GeneratorError.parse(
                        ParseError(
                            file: "\(run.input.name)/\(kind.rawValue)/\(name).\(kind.rawValue)",
                            line: 1,
                            message:
                                "\(noun) '\(name)' differs between distros — multi-distro \(noun) merging is not supported"
                        ))
                }
                union[index].distros.insert(run.input.distro)
            }
        }
        return union
    }

    /// Multi-package generation. All inputs are parsed first, then the resulting IRs
    /// are aggregated into a registry. Hashing and emission run after the registry is
    /// complete so cross-package references (e.g. `std_msgs/Header → builtin_interfaces/Time`)
    /// resolve regardless of the order packages appear in `runs`.
    ///
    /// Phase 4: when two `runs` share the same `input.name` (typically because
    /// the caller passed both a Humble and a Jazzy directory for the same
    /// package), the per-distro IDL files for each type are merged via
    /// ``IRBuilder/build(perDistro:)`` into a single distro-conditional IR.
    /// `unresolvedIRs` then carries one merged IR per `(package, typeName)`
    /// even though the source IDLs come from multiple distros.
    public static func generateMulti(
        _ runs: [PackageRun],
        extraImports: [String] = [],
        moduleNames: ModuleNames = [:]
    ) throws -> [GeneratedFile] {
        try ModuleIdentifier.validateAll(extraImports)
        let c = try collect(runs)
        // Precompute the modern (jazzy-view) hash for every IR. Single-distro
        // humble-only inputs do not need a Jazzy hash (humble has no RIHS01
        // anyway), but computing it is cheap and the per-distro projection
        // below decides whether to emit it. Hashing is per-distro so nested
        // type lookups in the registry get the same field projection as the
        // root.
        var hashByRosName: [String: String] = [:]
        for entry in c.unresolvedIRs {
            hashByRosName[entry.ir.rosTypeName] = RIHS01.hash(
                entry.ir, for: "jazzy", registry: c.registry)
        }
        var results: [GeneratedFile] = []
        for entry in c.unresolvedIRs {
            guard let primaryHash = hashByRosName[entry.ir.rosTypeName] else {
                preconditionFailure(
                    "Pipeline: missing precomputed hash for \(entry.ir.rosTypeName)"
                )
            }
            // The distributions whose IDL has the type (see ``CollectedIR/distros``). For a
            // humble-only type the emitted `typeInfo` advertises a `nil` humble hash.
            let distros = entry.distros
            var perDistroHashes: [String: String?] = [:]
            for distro in distros {
                if distro == "humble" {
                    // Humble has no RIHS01 — present in this distro, hash is nil.
                    perDistroHashes["humble"] = nil
                } else if IRBuilder.modernDistros.contains(distro) {
                    // Modern distros share the jazzy wire format and hash.
                    perDistroHashes[distro] = primaryHash
                }
            }
            // The non-conditional emit path keys on `perDistroHashes["jazzy"]`
            // for the static `typeInfo` constant. A humble-only single-distro
            // run does not naturally fill this in — plumb the primary
            // (computed-from-current-fields) hash so the emitter has
            // something to render. The conditional path uses the presence
            // map to decide which distros actually advertise the type.
            if perDistroHashes["jazzy"] == nil {
                perDistroHashes["jazzy"] = primaryHash
            }
            let hashed = MessageIR(
                package: entry.ir.package,
                typeName: entry.ir.typeName,
                kind: entry.ir.kind,
                fields: entry.ir.fields,
                constants: entry.ir.constants,
                perDistroHashes: perDistroHashes,
                perDistroFieldPresence: entry.ir.perDistroFieldPresence
            )
            let key = "\(entry.ir.package)/\(entry.ir.kind.rawValue)/\(entry.ir.typeName)"
            // Dependency-only packages are hashed above but emitted elsewhere.
            if c.dependencyPackages.contains(entry.ir.package) { continue }
            // Action IRs (the three user blocks + five wrappers) are emitted
            // together in a single per-action Swift file below, not as
            // standalone files.
            if entry.ir.kind == .action {
                continue
            }
            let nameOverride = c.nameOverrides[key]
            let isNested = Pipeline.defaultNestedOnlyTypes.contains(key)
            let swift = SwiftEmitter.emit(
                hashed,
                sourceLabel: entry.sourceLabel,
                isNested: isNested,
                structNameOverride: nameOverride,
                nestedNameOverrides: c.nameOverrides,
                extraImports: extraImports,
                moduleNames: moduleNames
            )
            let pascalPackage = pascal(entry.ir.package)
            let structName =
                nameOverride
                ?? SwiftEmitter.swiftStructName(typeName: entry.ir.typeName)
            results.append(
                GeneratedFile(
                    relativePath: "\(pascalPackage)/\(structName).swift",
                    contents: swift
                ))
        }
        // Phase 3: emit one umbrella enum per parsed `.srv` so callers can use
        // `<Service>Srv.Request` / `.Response` and read the canonical service-level
        // hashes from `typeInfo`. The umbrella reuses the per-half hashes that
        // already landed in the registry above.
        for svc in c.collectedServices where !c.dependencyPackages.contains(svc.package) {
            let reqKey = "\(svc.package)/srv/\(svc.typeName)_Request"
            let resKey = "\(svc.package)/srv/\(svc.typeName)_Response"
            let requestHash = hashByRosName[reqKey]
            let responseHash = hashByRosName[resKey]
            let requestStructName = c.nameOverrides[reqKey] ?? "\(svc.typeName)Request"
            let responseStructName = c.nameOverrides[resKey] ?? "\(svc.typeName)Response"
            let umbrellaName =
                Pipeline.defaultSwiftNameOverrides["\(svc.package)/srv/\(svc.typeName)"]
                ?? "\(svc.typeName)Srv"
            let umbrella = SwiftEmitter.emitServiceUmbrella(
                package: svc.package,
                serviceTypeName: svc.typeName,
                umbrellaName: umbrellaName,
                requestStructName: requestStructName,
                responseStructName: responseStructName,
                requestHash: requestHash,
                responseHash: responseHash,
                sourceLabel: "\(svc.package)/srv/\(svc.typeName).srv",
                extraImports: extraImports,
                moduleNames: moduleNames
            )
            let pascalPackage = pascal(svc.package)
            results.append(
                GeneratedFile(
                    relativePath: "\(pascalPackage)/\(umbrellaName).swift",
                    contents: umbrella
                ))
        }
        // Phase 6: emit one Swift file per parsed `.action`. Each file owns the
        // outer `<TypeName>Action` enum (with nested `Goal` / `Result` /
        // `Feedback`) plus the five sibling `<TypeName>_<Wrapper>` structs.
        // The action-level + wrapper hashes come from
        // ``IRBuilder/populateActionHashes(_:distro:extraRegistry:)`` which
        // reuses the global registry assembled above.
        for act in c.collectedActions where !c.dependencyPackages.contains(act.package) {
            var actionIR = act.actionIR
            IRBuilder.populateActionHashes(
                &actionIR, distro: "jazzy", extraRegistry: c.registry)
            let label = "\(act.package)/action/\(act.typeName).action"
            let swift = SwiftEmitter.emit(
                actionIR,
                sourceLabel: label,
                nestedNameOverrides: c.nameOverrides,
                extraImports: extraImports,
                moduleNames: moduleNames
            )
            let pascalPackage = pascal(act.package)
            results.append(
                GeneratedFile(
                    relativePath: "\(pascalPackage)/\(act.typeName)Action.swift",
                    contents: swift
                ))
        }
        return results
    }

    /// Oracle sample files for every emitted message, service half and action
    /// Goal / Result / Feedback: one `OracleSamples+<Pkg>.swift` per package and one
    /// `OracleSamples.swift` registry. Compiled into a repository's oracle corpus executable,
    /// never into a library product.
    ///
    /// Each sample lists the distributions whose IDL has its type, and the registry lists every
    /// distribution of the emitted runs, so `OracleSamples.samples(for:)` gives one
    /// distribution's corpus: an oracle image fails on a type its distribution lacks.
    ///
    /// A type of a dependency-only package gets an extension, in
    /// `OracleSamples_Dependencies.swift`, only when an emitted type reaches it through its
    /// fields (directly or through other dependency types), and never a sample of its own. The
    /// underscore keeps that name apart from `OracleSamples+<Pkg>.swift`: PascalCase package
    /// names contain no underscore, so no package, not even one called `dependencies`, can
    /// produce it.
    public static func generateOracleSamples(
        _ runs: [PackageRun], moduleNames: ModuleNames = [:]
    ) throws -> [GeneratedFile] {
        let c = try collect(runs)
        var extensionsByFile: [String: [String]] = [:]
        var packagesByFile: [String: Set<String>] = [:]
        var samples: [(rosName: String, swiftName: String, distros: Set<String>)] = []
        var distrosByRosName: [String: Set<String>] = [:]
        for entry in c.unresolvedIRs { distrosByRosName[entry.ir.rosTypeName] = entry.distros }
        // Dependency message types by ROS name, and the ones an added type references.
        var dependencyIRs: [String: MessageIR] = [:]
        for entry in c.unresolvedIRs where c.dependencyPackages.contains(entry.ir.package) {
            dependencyIRs[entry.ir.rosTypeName] = entry.ir
        }
        var reachedDependencyTypes: [String] = []

        func add(_ ir: MessageIR, swiftName: String, file: String, overrides: [String: String]) {
            extensionsByFile[file, default: []].append(
                OracleSampleEmitter.emitExtension(ir, structName: swiftName, nestedNameOverrides: overrides))
            packagesByFile[file, default: []].insert(ir.package)
            for field in ir.fields {
                packagesByFile[file, default: []].formUnion(field.type.referencedPackages)
                for name in field.type.referencedTypeNames where dependencyIRs[name] != nil {
                    reachedDependencyTypes.append(name)
                }
            }
        }

        // Messages and service halves of emitted packages. Action parts (kind == .action) are
        // handled below; dependency types only once an emitted type reaches them.
        for entry in c.unresolvedIRs
        where entry.ir.kind != .action && !c.dependencyPackages.contains(entry.ir.package) {
            let key = "\(entry.ir.package)/\(entry.ir.kind.rawValue)/\(entry.ir.typeName)"
            let swiftName = c.nameOverrides[key] ?? SwiftEmitter.swiftStructName(typeName: entry.ir.typeName)
            add(
                entry.ir, swiftName: swiftName, file: "OracleSamples+\(pascal(entry.ir.package)).swift",
                overrides: c.nameOverrides)
            samples.append((entry.ir.rosTypeName, swiftName, entry.distros))
        }
        // Action Goal / Result / Feedback, named as SwiftEmitter.emit(_ ir: ActionIR…) names them.
        for act in c.collectedActions where !c.dependencyPackages.contains(act.package) {
            let enumName = "\(act.typeName)Action"
            var overrides = c.nameOverrides
            for part in ["Goal", "Result", "Feedback"] {
                overrides["\(act.package)/action/\(act.typeName)_\(part)"] = "\(enumName).\(part)"
            }
            let file = "OracleSamples+\(pascal(act.package)).swift"
            let distros = distrosByRosName[act.actionIR.goal.rosTypeName] ?? []
            for (part, ir) in [
                ("Goal", act.actionIR.goal), ("Result", act.actionIR.result), ("Feedback", act.actionIR.feedback),
            ] {
                add(ir, swiftName: "\(enumName).\(part)", file: file, overrides: overrides)
                samples.append(("\(act.package)/action/\(act.typeName)_\(part)", "\(enumName).\(part)", distros))
            }
        }
        // Dependency types the emitted types reach, transitively. They get an extension (nested
        // fields call it) but no sample of their own: their package's repository tests them.
        var addedDependencyTypes = Set<String>()
        while let name = reachedDependencyTypes.popLast() {
            guard addedDependencyTypes.insert(name).inserted, let ir = dependencyIRs[name] else { continue }
            let swiftName = c.nameOverrides[name] ?? SwiftEmitter.swiftStructName(typeName: ir.typeName)
            add(ir, swiftName: swiftName, file: "OracleSamples_Dependencies.swift", overrides: c.nameOverrides)
        }

        // The generated-file banner plus one lexicographically sorted import block (swift-format's
        // `OrderedImports`), so a corpus target that lints its sources passes.
        func header(packages: Set<String>) -> String {
            let modules = Set(
                ["Foundation", ModuleImports.cdrModule]
                    + ModuleImports.imports(referencing: packages, moduleNames: moduleNames)
            ).sorted()
            return "// Generated by swift-ros2-gen \u{2014} DO NOT EDIT.\n\n"
                + modules.map { "import \($0)\n" }.joined()
        }
        var files: [GeneratedFile] = []
        for (file, extensions) in extensionsByFile.sorted(by: { $0.key < $1.key }) {
            let out = header(packages: packagesByFile[file] ?? []) + "\n" + extensions.joined(separator: "\n")
            files.append(GeneratedFile(relativePath: file, contents: out))
        }
        let allPackages = packagesByFile.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        // Distributions as a Swift array literal, in `IRBuilder.distroOrder` order.
        func literal(_ distros: Set<String>) -> String {
            let known = IRBuilder.distroOrder.filter(distros.contains)
            let ordered = known + distros.subtracting(known).sorted()
            return "[" + ordered.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
        }
        // Generated types give Rolling the modern hash of the newest named distribution.
        let rollingStandIn = IRBuilder.distroOrder.last { $0 != "rolling" } ?? "rolling"
        var registry = header(packages: allPackages)
        registry += """

            /// One CDR oracle sample: the ROS name, the distributions whose IDL has the type, the
            /// CDR bytes Swift produces for it, and a decode-then-encode of given bytes as the same
            /// type (the Swift round-trip).
            struct OracleSample {
                let rosName: String
                let distributions: Set<String>
                let encode: () throws -> Data
                let reencode: (Data) throws -> Data
            }

            /// The samples of this run.
            enum OracleSamples {
                /// Every distribution this run read IDL for.
                static let distributions: Set<String> = \(literal(Set(runs.filter(\.emit).map(\.input.distro))))

                /// The samples of the types `distro` has, or nil when this run read no IDL for
                /// `distro`. Without Rolling IDL, Rolling has the \(rollingStandIn.capitalized) samples: generated types
                /// give Rolling the modern (\(rollingStandIn.capitalized)) hash.
                static func samples(for distro: String) -> [OracleSample]? {
                    let source = distro == "rolling" && !distributions.contains("rolling") ? "\(rollingStandIn)" : distro
                    guard distributions.contains(source) else { return nil }
                    return all.filter { $0.distributions.contains(source) }
                }

                /// Every sample, in ROS-name order.
                static let all: [OracleSample] = [

            """
        for sample in samples.sorted(by: { $0.rosName < $1.rosName }) {
            registry += "        OracleSample(\n"
            registry += "            rosName: \"\(sample.rosName)\",\n"
            registry += "            distributions: \(literal(sample.distros)),\n"
            registry += "            encode: { try oracleEncode(\(sample.swiftName).oracleSample()) },\n"
            registry += "            reencode: { try oracleReencode(\(sample.swiftName).self, $0) }),\n"
        }
        registry += """
                ]
            }

            func oracleEncode<T: CDREncodable>(_ value: T) throws -> Data {
                let encoder = CDREncoder()
                encoder.writeEncapsulationHeader()
                try value.encode(to: encoder)
                return encoder.getData()
            }

            func oracleReencode<T: CDRCodable>(_ type: T.Type, _ data: Data) throws -> Data {
                try oracleEncode(T(from: CDRDecoder(data: data)))
            }

            """
        files.append(GeneratedFile(relativePath: "OracleSamples.swift", contents: registry))
        return files
    }

    /// Lightweight carrier for an as-parsed `.srv`: keeps the two halves' raw IDLFiles
    /// so the umbrella emitter can recompute hashes if the post-hashing registry
    /// lookup miscarries. The request / response halves themselves are emitted via
    /// the regular message emission path; this struct only describes the umbrella.
    public struct ParsedService: Equatable, Sendable {
        public let package: String
        public let typeName: String
        public let requestIDL: IDLFile
        public let responseIDL: IDLFile

        public init(package: String, typeName: String, requestIDL: IDLFile, responseIDL: IDLFile) {
            self.package = package
            self.typeName = typeName
            self.requestIDL = requestIDL
            self.responseIDL = responseIDL
        }
    }

    private struct ParsedEntry {
        let ir: MessageIR
        let sourceLabel: String
        /// The distributions whose IDL has the type.
        let distros: Set<String>
    }

    /// Throw ``GeneratorError/packageDirectoryMissing(_:)`` when `directory`
    /// does not exist or is not a directory. Used by every `--input` consumer
    /// before tolerating a missing `msg/` or `srv/` subdirectory, so a typo'd
    /// `--input` path surfaces as a hard error rather than as an empty
    /// (single-package path) or partial (multi-distro path) success.
    private static func requirePackageDirectory(_ directory: URL) throws {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir)
        guard exists, isDir.boolValue else {
            throw GeneratorError.packageDirectoryMissing(directory)
        }
    }

    /// Same parse-and-IR walk as ``generateMulti`` but stops short of
    /// emission. Used by `swift-ros2-gen --verify-hashes` to diff every
    /// generator-computed RIHS01 against the canonical rosidl oracle without
    /// touching the filesystem.
    ///
    /// Each returned ``VerifyPlanEntry`` carries the in-process IR, the
    /// generator-computed hash for the requested distro, and the
    /// ``topLevelTypeName`` of the IDL file that produced it (e.g. for
    /// `Fibonacci_SendGoal_Request` the top-level type is `Fibonacci`). The
    /// verifier groups entries by `(package, kind, topLevelTypeName, distro)`
    /// so it issues exactly one oracle JSON read per source IDL file.
    public static func buildVerifyPlan(
        _ runs: [PackageRun],
        distros allowedDistros: Set<String>? = nil
    ) throws -> [VerifyPlanEntry] {
        // Reuse the multi-package gather + register sequence of generateMulti so
        // cross-package nested references resolve.
        let c = try collect(runs)

        // For each distro the caller asked about (default: every distro whose IDL
        // has the type), compute the per-distro hash and emit one VerifyPlanEntry
        // per (ir, distro) pair. A type is in scope only for the distributions
        // whose IDL has it (``CollectedIR/distros``): a single run's own
        // distribution, or for a package read from several distributions the ones
        // that have the message, service or action.
        var out: [VerifyPlanEntry] = []
        for entry in c.unresolvedIRs {
            for distro in entry.distros.sorted() {
                if let allow = allowedDistros, !allow.contains(distro) { continue }
                // Humble does not have a hash oracle; rosidl pre-RIHS01.
                // Skip silently to keep the verify-mode focused on the
                // distros the rosidl `.json` files actually exist for.
                if distro == "humble" { continue }
                let hash = RIHS01.hash(entry.ir, for: distro, registry: c.registry)
                out.append(
                    VerifyPlanEntry(
                        package: entry.ir.package,
                        kind: entry.ir.kind,
                        typeName: entry.ir.typeName,
                        topLevelTypeName: entry.topLevelTypeName,
                        distro: distro,
                        expectedHash: hash
                    ))
            }
        }
        // NOTE: the action-level `<pkg>/action/<Type>` description is *not*
        // verified here. rosidl's canonical action-level type description
        // is built from the three constituent services (SendGoal,
        // GetResult, FeedbackMessage), not as a flat record of three
        // nested fields the way `IRBuilder.populateActionHashes`
        // synthesizes it for the generator's local typeInfo. The eight
        // wrapper / block hashes (which carry the wire format) are
        // verified above; the action-level hash drift is tracked as a
        // separate generator follow-up.
        out.removeAll { c.dependencyPackages.contains($0.package) }
        return out
    }
}

/// One in-process expectation produced by ``Pipeline/buildVerifyPlan(_:distros:)``.
public struct VerifyPlanEntry: Sendable, Equatable {
    public let package: String
    public let kind: MessageKind
    /// Sub-type name (e.g. `"Fibonacci_SendGoal_Request"`).
    public let typeName: String
    /// Outermost IDL stem the oracle JSON file is named after (e.g.
    /// `"Fibonacci"`). The verifier groups requests by this stem so it
    /// issues exactly one `docker run cat <Type>.json` per source file.
    public let topLevelTypeName: String
    public let distro: String
    public let expectedHash: String

    /// Canonical ROS type name used for `type_hashes[*].type_name` lookup
    /// in the oracle JSON.
    public var rosTypeName: String { "\(package)/\(kind.rawValue)/\(typeName)" }

    public init(
        package: String,
        kind: MessageKind,
        typeName: String,
        topLevelTypeName: String,
        distro: String,
        expectedHash: String
    ) {
        self.package = package
        self.kind = kind
        self.typeName = typeName
        self.topLevelTypeName = topLevelTypeName
        self.distro = distro
        self.expectedHash = expectedHash
    }
}

extension Pipeline {
    private static func parsePackage(run: PackageRun) throws -> [ParsedEntry] {
        // Reject typo'd / nonexistent package directories up-front so the
        // srv-only tolerance below cannot mask a bad `--input` path.
        try requirePackageDirectory(run.input.directory)
        let msgDir = run.input.directory.appendingPathComponent("msg", isDirectory: true)
        var isDir: ObjCBool = false
        let msgExists =
            FileManager.default.fileExists(atPath: msgDir.path, isDirectory: &isDir)
            && isDir.boolValue
        guard msgExists else {
            // A package without a msg/ directory is valid when it ships only
            // services (e.g. std_srvs) or actions. Return empty here; the
            // caller still walks srv/ via parseServicesIn.
            return []
        }
        let entries = try FileManager.default.contentsOfDirectory(
            at: msgDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let msgFiles =
            entries
            .filter { $0.pathExtension == "msg" }
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        var parsed: [ParsedEntry] = []
        for fileURL in msgFiles {
            let typeName = fileURL.deletingPathExtension().lastPathComponent
            if let allow = run.typesAllowList, !allow.contains(typeName) { continue }
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            let label = sourceLabelFor(run: run, typeName: typeName, kind: .msg)
            do {
                let idl = try Parser.parseMessage(
                    source: contents,
                    file: label,
                    package: run.input.name,
                    typeName: typeName
                )
                let ir = IRBuilder.build(jazzy: idl)
                parsed.append(ParsedEntry(ir: ir, sourceLabel: label, distros: [run.input.distro]))
            } catch let err as ParseError {
                throw GeneratorError.parse(err)
            }
        }
        return parsed
    }

    /// Produce a stable `// Source:` label for emitted Swift files. The label
    /// is informational only (it never affects the wire format), but tests
    /// and goldens key on it. We prefix with the parent vendor directory
    /// (`common_interfaces-jazzy`, etc.) when that name unambiguously
    /// identifies the upstream IDL source; bare names like `vendor` or
    /// repository roots that happen to be the immediate parent are stripped.
    private static func sourceLabelFor(
        run: PackageRun,
        typeName: String,
        kind: MessageKind
    ) -> String {
        let parent = run.input.directory.deletingLastPathComponent().lastPathComponent
        let suffix = "\(run.input.name)/\(kind.rawValue)/\(typeName).\(kind.rawValue)"
        if parent.isEmpty || parent == "vendor" || parent == "Vendor" {
            return suffix
        }
        // Strip a `<repo>-<distro>` parent down to its base when the package
        // is not the canonical sibling of that repo (e.g. action_msgs lives
        // under `rcl_interfaces-jazzy/`, but the historical labels emitted
        // it bare). The rule: keep the parent only when it begins with
        // `common_interfaces` (the one repo where the prefixed label was
        // historically committed).
        if parent.hasPrefix("common_interfaces") {
            return "\(parent)/\(suffix)"
        }
        return suffix
    }

    /// Enumerate `<pkg>/srv/*.srv` for the run, parse each into request / response
    /// halves, and return them as ``ParsedService`` carriers. Returns an empty
    /// array when the package has no `srv/` subdirectory at all (the common case
    /// for pure message packages like `std_msgs`). The same `typesAllowList`
    /// filter applies as for messages — it matches the bare service name
    /// (`CancelGoal`).
    private static func parseServicesIn(run: PackageRun) throws -> [ParsedService] {
        // Same guard as parsePackage: a missing package directory must surface
        // as a hard error rather than as an empty service list.
        try requirePackageDirectory(run.input.directory)
        let srvDir = run.input.directory.appendingPathComponent("srv", isDirectory: true)
        var isDir: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: srvDir.path, isDirectory: &isDir),
            isDir.boolValue
        else {
            return []
        }
        let entries = try FileManager.default.contentsOfDirectory(
            at: srvDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let srvFiles =
            entries
            .filter { $0.pathExtension == "srv" }
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        var out: [ParsedService] = []
        for fileURL in srvFiles {
            let typeName = fileURL.deletingPathExtension().lastPathComponent
            if let allow = run.typesAllowList, !allow.contains(typeName) { continue }
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            let label = sourceLabelFor(run: run, typeName: typeName, kind: .srv)
            do {
                let svc = try Parser.parseService(
                    source: contents,
                    file: label,
                    package: run.input.name,
                    typeName: typeName
                )
                out.append(
                    ParsedService(
                        package: run.input.name,
                        typeName: typeName,
                        requestIDL: svc.request,
                        responseIDL: svc.response
                    ))
            } catch let err as ParseError {
                throw GeneratorError.parse(err)
            }
        }
        return out
    }

    /// Phase 4 helper. Parses every `.msg` in each `pkgRuns[*].input.directory/msg`
    /// and groups the IDLFiles by type name; for each group, calls
    /// ``IRBuilder/build(perDistro:)`` to produce a single distro-conditional IR.
    /// `pkgRuns` must all share the same `input.name` — the caller in
    /// ``generateMulti`` already enforces that.
    private static func parseAndMergeMultiDistroPackage(
        runs pkgRuns: [PackageRun]
    ) throws -> [ParsedEntry] {
        precondition(!pkgRuns.isEmpty, "parseAndMergeMultiDistroPackage: empty runs")
        let packageName = pkgRuns[0].input.name
        precondition(
            pkgRuns.allSatisfy { $0.input.name == packageName },
            "parseAndMergeMultiDistroPackage: all runs must share the same package name")

        // Per-distro IDL collections, indexed by type name.
        var idlsByType: [String: [String: IDLFile]] = [:]
        var typeOrder: [String] = []
        // Pick the most-permissive type allow-list across the runs (a type
        // appears in the merge if any run lists it). Practically every run
        // shares the same allow-list because the CLI applies the same
        // `--types` filter to every input.
        var unifiedAllowList: Set<String>? = nil
        for run in pkgRuns {
            if let allow = run.typesAllowList {
                if unifiedAllowList == nil { unifiedAllowList = [] }
                unifiedAllowList?.formUnion(allow)
            }
        }

        for run in pkgRuns {
            // Validate the per-distro `--input` path before falling through to
            // the msg/ tolerance: a typo'd directory must not be silently
            // skipped (which would yield a partial multi-distro merge with no
            // diagnostics), only the absence of the `msg/` subdirectory inside
            // an otherwise-valid package directory is tolerated.
            try requirePackageDirectory(run.input.directory)
            let msgDir = run.input.directory.appendingPathComponent("msg", isDirectory: true)
            var isDir: ObjCBool = false
            let msgExists =
                FileManager.default.fileExists(atPath: msgDir.path, isDirectory: &isDir)
                && isDir.boolValue
            guard msgExists else {
                // Service-only packages (no msg/ directory) are tolerated;
                // the multi-distro path simply contributes no message IRs
                // for that distro.
                continue
            }
            let entries = try FileManager.default.contentsOfDirectory(
                at: msgDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            let msgFiles =
                entries
                .filter { $0.pathExtension == "msg" }
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            for fileURL in msgFiles {
                let typeName = fileURL.deletingPathExtension().lastPathComponent
                if let allow = unifiedAllowList, !allow.contains(typeName) { continue }
                let contents = try String(contentsOf: fileURL, encoding: .utf8)
                // Derive the parent name from the actual filesystem directory
                // (the `<idl-root>` in `<idl-root>/std_msgs/msg/Header.msg`) so a
                // renamed IDL root is reflected in the label.
                let parentDir = run.input.directory.deletingLastPathComponent().lastPathComponent
                let label = "\(parentDir)/\(packageName)/msg/\(typeName).msg"
                do {
                    let idl = try Parser.parseMessage(
                        source: contents,
                        file: label,
                        package: packageName,
                        typeName: typeName
                    )
                    if idlsByType[typeName] == nil { typeOrder.append(typeName) }
                    idlsByType[typeName, default: [:]][run.input.distro] = idl
                } catch let err as ParseError {
                    throw GeneratorError.parse(err)
                }
            }
        }

        var parsed: [ParsedEntry] = []
        for typeName in typeOrder {
            guard let perDistroIDL = idlsByType[typeName] else { continue }
            let mergedIR = try IRBuilder.build(perDistro: perDistroIDL)
            // Use a stable label that names every distro the type came from.
            // The parent comes from the first run's vendor parent directory
            // ("common_interfaces" or similar) plus a `+`-joined distro list.
            let distros =
                perDistroIDL.keys.sorted().joined(separator: "+")
            let parentDir =
                pkgRuns.first!.input.directory.deletingLastPathComponent().lastPathComponent
            // Strip any trailing `-<distro>` suffix from the parent so the
            // label reads e.g. `common_interfaces-humble+jazzy/sensor_msgs/...`.
            let baseParent: String = {
                if let dashIdx = parentDir.firstIndex(of: "-") {
                    return String(parentDir[..<dashIdx])
                }
                return parentDir
            }()
            let label = "\(baseParent)-\(distros)/\(packageName)/msg/\(typeName).msg"
            parsed.append(ParsedEntry(ir: mergedIR, sourceLabel: label, distros: Set(perDistroIDL.keys)))
        }
        return parsed
    }

    /// Parse every `.msg` across `runs` and assemble a fully-resolved
    /// `[rosTypeName: MessageIR]` registry (keyed by `<pkg>/msg/<Type>`). Unlike
    /// ``generateMulti``, this stops short of hashing / emission — it exists so
    /// callers can recurse into nested message IRs
    /// (`std_msgs/Header → builtin_interfaces/Time`, …) without
    /// re-implementing the cross-package gather.
    ///
    /// Single-distro IRs only: no per-distro merge is performed. Service and
    /// action IRs are intentionally excluded; only `.msg` types are returned.
    ///
    /// Throws ``GeneratorError/unresolvedNestedType(package:typeName:)`` when a
    /// nested reference cannot be resolved from the supplied `runs`.
    public static func buildMessageRegistry(_ runs: [PackageRun]) throws -> [String: MessageIR] {
        var registry: [String: MessageIR] = [:]
        for run in runs.map(\.parseRun) {
            for entry in try parsePackage(run: run) {
                registry[entry.ir.rosTypeName] = entry.ir
            }
        }
        try validateAllReferencesResolved(registry: registry)
        return registry
    }

    private static func validateAllReferencesResolved(registry: [String: MessageIR]) throws {
        for (_, ir) in registry {
            for field in ir.fields {
                guard let target = elementNestedReference(of: field.type) else { continue }
                // Phase 6: a nested reference may resolve under msg, srv, or
                // action — accept the first kind found in the registry.
                var resolved = false
                for kind in MessageKind.allCases {
                    if registry["\(target.package)/\(kind.rawValue)/\(target.typeName)"] != nil {
                        resolved = true
                        break
                    }
                }
                if !resolved {
                    throw GeneratorError.unresolvedNestedType(package: target.package, typeName: target.typeName)
                }
            }
        }
    }

    /// The nested type a field ultimately refers to, looking through fixed-size arrays and
    /// sequences (bounded or not). `nil` for primitives and strings.
    private static func elementNestedReference(of fieldType: FieldType) -> (package: String, typeName: String)? {
        switch fieldType {
        case .primitive, .boundedString:
            return nil
        case .nested(let package, let typeName):
            return (package, typeName)
        case .array(let element, _), .sequence(let element, _):
            return elementNestedReference(of: element)
        }
    }
}

extension Pipeline {
    /// Lightweight carrier for an as-parsed `.action`. The fully-built
    /// ``ActionIR`` lives here so the emitter can read out the eight contained
    /// ``MessageIR``s plus the per-distro hash bundle without re-running the
    /// builder.
    public struct ParsedAction: Equatable, Sendable {
        public let package: String
        public let typeName: String
        public let actionIR: ActionIR

        public init(package: String, typeName: String, actionIR: ActionIR) {
            self.package = package
            self.typeName = typeName
            self.actionIR = actionIR
        }
    }

    /// Enumerate `<pkg>/action/*.action` for the run, parse each into the
    /// three user-defined blocks + five synthesized wrappers via
    /// ``IRBuilder/build(jazzy:)``, and return them as ``ParsedAction``
    /// carriers. Returns an empty array when the package has no `action/`
    /// subdirectory at all (the common case for pure message / service
    /// packages). The same `typesAllowList` filter applies as for messages —
    /// it matches the bare action type name (`Fibonacci`).
    public static func parseActionsIn(run: PackageRun) throws -> [ParsedAction] {
        let actionDir = run.input.directory.appendingPathComponent("action", isDirectory: true)
        var isDir: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: actionDir.path, isDirectory: &isDir),
            isDir.boolValue
        else {
            return []
        }
        let entries = try FileManager.default.contentsOfDirectory(
            at: actionDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let actionFiles =
            entries
            .filter { $0.pathExtension == "action" }
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        var out: [ParsedAction] = []
        for fileURL in actionFiles {
            let typeName = fileURL.deletingPathExtension().lastPathComponent
            if let allow = run.typesAllowList, !allow.contains(typeName) { continue }
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            let label = sourceLabelFor(run: run, typeName: typeName, kind: .action)
            do {
                let idl = try Parser.parseAction(
                    source: contents,
                    file: label,
                    package: run.input.name,
                    typeName: typeName
                )
                let ir = IRBuilder.build(jazzy: idl)
                out.append(
                    ParsedAction(
                        package: run.input.name,
                        typeName: typeName,
                        actionIR: ir
                    ))
            } catch let err as ParseError {
                throw GeneratorError.parse(err)
            }
        }
        return out
    }
}
