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
        case .conflictingPackageRoles(let name):
            return "package '\(name)' is passed both as --input and as --dependency"
        case .modernDistroDivergence(let type, let field, let presentIn, let missingFrom):
            return
                "\(type): field '\(field)' exists in \(presentIn) but not in \(missingFrom) — generated types support one modern shape (Jazzy and later); differences among modern distributions are not supported"
        }
    }
}

/// Module-name validation for the CLI's `--module` values, so user input cannot be spliced
/// verbatim into emitted `import` lines. A valid module identifier matches
/// `[A-Za-z_][A-Za-z0-9_]*`, optionally dotted for nested modules (e.g. `Foo.Bar`).
/// Whitespace, quotes, and newlines are all rejected.
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
    /// Runs an IR build of the IDL file labelled `file`, reporting an ``IRBuildError`` as a
    /// ``GeneratorError/parse(_:)`` at the line it is about.
    static func buildIR<T>(file: String, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as IRBuildError {
            throw GeneratorError.parse(ParseError(file: file, line: error.line ?? 1, message: error.message))
        }
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
                            ir: entry.ir, sourceLabel: entry.sourceLabel,
                            topLevelTypeName: entry.ir.typeName, distros: entry.distros))
                }
            } else {
                // Multi-distro path: parse each run's IDLs, group by type name,
                // then merge per-distro IDLs via IRBuilder.build(perDistro:).
                for entry in try parseAndMergeMultiDistroPackage(runs: pkgRuns) {
                    try validateModernAgreement(entry.ir)
                    unresolvedIRs.append(
                        CollectedIR(
                            ir: entry.ir, sourceLabel: entry.sourceLabel,
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
                let label = sourceLabel(package: svc.package, typeName: svc.typeName, kind: .srv)
                for half in [svc.requestIDL, svc.responseIDL] {
                    let ir = try buildIR(file: label) { try IRBuilder.build(jazzy: half, kind: .srv) }
                    unresolvedIRs.append(
                        CollectedIR(
                            ir: ir, sourceLabel: label,
                            topLevelTypeName: svc.typeName, distros: distros))
                }
            }
            collectedServices.append(contentsOf: services.map(\.item))

            let actions = try unionAcrossDistros(
                pkgRuns, kind: .action, parse: parseActionsIn, typeName: \.typeName)
            for (act, distros) in actions {
                let label = sourceLabel(package: act.package, typeName: act.typeName, kind: .action)
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
                            ir: ir, sourceLabel: label, topLevelTypeName: act.typeName,
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
        // The types rosidl adds to service and action type descriptions, for the service-level
        // and action-level hashes. Added after the reference check: they are never emitted.
        for svc in collectedServices {
            ServiceDescription.register(
                package: svc.package, kind: .srv, serviceName: svc.typeName, into: &registry)
        }
        for act in collectedActions {
            ServiceDescription.register(action: act.actionIR, into: &registry)
        }
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
        moduleNames: ModuleNames = [:]
    ) throws -> [GeneratedFile] {
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
            let serviceHash = RIHS01.hash(
                ServiceDescription.serviceIR(package: svc.package, kind: .srv, serviceName: svc.typeName),
                for: "jazzy", registry: c.registry)
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
                serviceHash: serviceHash,
                sourceLabel: sourceLabel(package: svc.package, typeName: svc.typeName, kind: .srv),
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
            let swift = SwiftEmitter.emit(
                actionIR,
                sourceLabel: sourceLabel(package: act.package, typeName: act.typeName, kind: .action),
                nestedNameOverrides: c.nameOverrides,
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

    /// One IDL file of a package: the type it defines (the file stem), its location and its text.
    private struct IDLSource {
        let typeName: String
        let url: URL
        let contents: String
    }

    /// The `msg/*.msg`, `srv/*.srv` or `action/*.action` files (by `kind`) of the package of
    /// `run` whose type name passes `allowList`, sorted by file name. A package without that
    /// subdirectory has none, since a package may ship only messages, services or actions. A
    /// missing package directory throws ``GeneratorError/packageDirectoryMissing(_:)``, so a
    /// typo'd `--input` path is never read as an empty package.
    private static func idlSources(
        of run: PackageRun, kind: MessageKind, allowList: Set<String>?
    ) throws -> [IDLSource] {
        var isDir: ObjCBool = false
        let packageDirectory = run.input.directory
        guard FileManager.default.fileExists(atPath: packageDirectory.path, isDirectory: &isDir), isDir.boolValue
        else {
            throw GeneratorError.packageDirectoryMissing(packageDirectory)
        }
        let directory = packageDirectory.appendingPathComponent(kind.rawValue, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }
        return try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == kind.rawValue }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .compactMap { url in
            let typeName = url.deletingPathExtension().lastPathComponent
            if let allowList, !allowList.contains(typeName) { return nil }
            return IDLSource(typeName: typeName, url: url, contents: try String(contentsOf: url, encoding: .utf8))
        }
    }

    /// The `// Source:` label of a generated file, `<package>/<kind>/<Type>.<kind>`. It is the same
    /// for messages, services and actions, and does not depend on the directory the IDL was read
    /// from or on the distributions it was read for.
    static func sourceLabel(package: String, typeName: String, kind: MessageKind) -> String {
        "\(package)/\(kind.rawValue)/\(typeName).\(kind.rawValue)"
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
        // The types rosidl adds to service and action type descriptions (see
        // ``ServiceDescription``): every service's service-level and `_Event` types, and every
        // action's action-level type plus its `_SendGoal` / `_GetResult` services and their
        // `_Event` types. Each is in scope for the distributions of the service or action.
        func distros(of rosTypeName: String) -> Set<String> {
            c.unresolvedIRs.first { $0.ir.rosTypeName == rosTypeName }?.distros ?? []
        }
        var synthesized: [(ir: MessageIR, topLevel: String, distros: Set<String>)] = []
        for svc in c.collectedServices {
            let svcDistros = distros(of: "\(svc.package)/srv/\(svc.typeName)_Request")
            for name in [svc.typeName, "\(svc.typeName)_Event"] {
                if let ir = c.registry["\(svc.package)/srv/\(name)"] {
                    synthesized.append((ir, svc.typeName, svcDistros))
                }
            }
        }
        for act in c.collectedActions {
            let actDistros = distros(of: act.actionIR.goal.rosTypeName)
            for name in [
                act.typeName, "\(act.typeName)_SendGoal", "\(act.typeName)_SendGoal_Event",
                "\(act.typeName)_GetResult", "\(act.typeName)_GetResult_Event",
            ] {
                if let ir = c.registry["\(act.package)/action/\(name)"] {
                    synthesized.append((ir, act.typeName, actDistros))
                }
            }
        }
        for (ir, topLevel, irDistros) in synthesized {
            for distro in irDistros.sorted() where distro != "humble" {
                if let allow = allowedDistros, !allow.contains(distro) { continue }
                out.append(
                    VerifyPlanEntry(
                        package: ir.package, kind: ir.kind, typeName: ir.typeName, topLevelTypeName: topLevel,
                        distro: distro, expectedHash: RIHS01.hash(ir, for: distro, registry: c.registry)))
            }
        }
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
    /// Parses the `.msg` files of one run. Parse errors name the file's path.
    private static func parsePackage(run: PackageRun) throws -> [ParsedEntry] {
        try idlSources(of: run, kind: .msg, allowList: run.typesAllowList).map { source in
            let idl = try parse {
                try Parser.parseMessage(
                    source: source.contents, file: source.url.path, package: run.input.name,
                    typeName: source.typeName)
            }
            return ParsedEntry(
                ir: try buildIR(file: source.url.path) { try IRBuilder.build(jazzy: idl) },
                sourceLabel: sourceLabel(package: run.input.name, typeName: source.typeName, kind: .msg),
                distros: [run.input.distro])
        }
    }

    /// Runs a parser call, reporting a ``ParseError`` as ``GeneratorError/parse(_:)``.
    private static func parse<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as ParseError {
            throw GeneratorError.parse(error)
        }
    }

    /// Parses the `.srv` files of one run into request / response halves, as ``ParsedService``
    /// carriers. The type allow-list matches the bare service name (`CancelGoal`).
    private static func parseServicesIn(run: PackageRun) throws -> [ParsedService] {
        try idlSources(of: run, kind: .srv, allowList: run.typesAllowList).map { source in
            let svc = try parse {
                try Parser.parseService(
                    source: source.contents, file: source.url.path, package: run.input.name,
                    typeName: source.typeName)
            }
            return ParsedService(
                package: run.input.name, typeName: source.typeName, requestIDL: svc.request,
                responseIDL: svc.response)
        }
    }

    /// Parses the `.msg` files of every run of one package (one run per distribution) and merges
    /// the per-distribution IDL of each type with ``IRBuilder/build(perDistro:)`` into one
    /// distro-conditional IR. `pkgRuns` all share one package name; ``collect(_:)`` groups them.
    private static func parseAndMergeMultiDistroPackage(
        runs pkgRuns: [PackageRun]
    ) throws -> [ParsedEntry] {
        precondition(!pkgRuns.isEmpty, "parseAndMergeMultiDistroPackage: empty runs")
        let packageName = pkgRuns[0].input.name
        precondition(
            pkgRuns.allSatisfy { $0.input.name == packageName },
            "parseAndMergeMultiDistroPackage: all runs must share the same package name")

        // A type takes part in the merge when any run's allow-list has it. The CLI gives every
        // run the same `--types` filter.
        var unifiedAllowList: Set<String>? = nil
        for run in pkgRuns {
            if let allow = run.typesAllowList {
                unifiedAllowList = (unifiedAllowList ?? []).union(allow)
            }
        }

        // Per-distro IDL of each type, and the types in first-seen order.
        var idlsByType: [String: [String: IDLFile]] = [:]
        var typeOrder: [String] = []
        for run in pkgRuns {
            for source in try idlSources(of: run, kind: .msg, allowList: unifiedAllowList) {
                let idl = try parse {
                    try Parser.parseMessage(
                        source: source.contents, file: source.url.path, package: packageName,
                        typeName: source.typeName)
                }
                // Validate each distribution's defaults and constants against its own file,
                // so an error names the file and line it comes from.
                _ = try buildIR(file: source.url.path) { try IRBuilder.build(jazzy: idl) }
                if idlsByType[source.typeName] == nil { typeOrder.append(source.typeName) }
                idlsByType[source.typeName, default: [:]][run.input.distro] = idl
            }
        }

        return try typeOrder.map { typeName in
            let perDistroIDL = idlsByType[typeName]!
            return ParsedEntry(
                ir: try IRBuilder.build(perDistro: perDistroIDL),
                sourceLabel: sourceLabel(package: packageName, typeName: typeName, kind: .msg),
                distros: Set(perDistroIDL.keys))
        }
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

    /// Parses the `.action` files of one run into the three user-defined blocks and the five
    /// synthesized wrappers, as ``ParsedAction`` carriers. A package without an `action/`
    /// directory has none; a missing package directory throws
    /// ``GeneratorError/packageDirectoryMissing(_:)``. The type allow-list matches the bare
    /// action name (`Fibonacci`).
    public static func parseActionsIn(run: PackageRun) throws -> [ParsedAction] {
        try idlSources(of: run, kind: .action, allowList: run.typesAllowList).map { source in
            let idl = try parse {
                try Parser.parseAction(
                    source: source.contents, file: source.url.path, package: run.input.name,
                    typeName: source.typeName)
            }
            let ir = try buildIR(file: source.url.path) { try IRBuilder.build(jazzy: idl) }
            return ParsedAction(package: run.input.name, typeName: source.typeName, actionIR: ir)
        }
    }
}
