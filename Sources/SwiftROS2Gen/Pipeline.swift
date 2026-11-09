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
    /// A field exists in distributions that are not one contiguous run of the distributions
    /// read for its type, for example in Jazzy and Lyrical but not Kilted between them.
    /// `missingFrom` lists the read distributions between them that lack it.
    ///
    /// The pipeline no longer throws it: like every type that cannot be merged across
    /// distributions, such a field is reported as ``parse(_:)`` at its line in the IDL file of
    /// the distribution that has it again.
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
            func list(_ distros: [String]) -> String { "[" + distros.joined(separator: ", ") + "]" }
            return
                "\(type): field '\(field)' exists in \(list(presentIn)) but not in \(list(missingFrom)) between them — a field must exist in one contiguous run of distributions"
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

/// Maps `<pkg>/<kind>/<TypeName>` → Swift struct name, replacing the default
/// ``SwiftEmitter/swiftStructName(typeName:)`` output (for example `UniqueIdentifierUUID`
/// for `unique_identifier_msgs/msg/UUID`, which would otherwise be `UUID`).
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
    /// Types such as `builtin_interfaces/Time` or `std_msgs/Header` are also embedded, but they
    /// are full `ROS2Message` types because they are published on their own too. Adding one
    /// here would remove its `typeInfo` and `ROS2Message` conformance.
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

    /// The first field of `ir` that is missing from a read distribution between two that have
    /// it, with the distributions that have it and the ones between them that lack it.
    ///
    /// Generated code tells whether a distribution has a field by comparing it with the first
    /// read distribution that has the field and the first one after them that lacks it
    /// (`schemaDistro >= .lyrical`), so a field must exist in one contiguous run of the
    /// distributions `readDistros` read for its type, Humble included.
    static func distroGap(
        in ir: MessageIR, readDistros: Set<String>
    ) -> (field: String, presentIn: [String], missingFrom: [String])? {
        let ordered = IRBuilder.distroOrder.filter(readDistros.contains)
        for field in ir.fields {
            guard case .onlyIn(let present) = field.availability,
                let first = ordered.firstIndex(where: present.contains),
                let last = ordered.lastIndex(where: present.contains)
            else { continue }
            let gap = ordered[first...last].filter { !present.contains($0) }
            if !gap.isEmpty {
                return (field.ros2Name, ordered.filter(present.contains), gap)
            }
        }
        return nil
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
            for message in try mergeAcrossDistros(pkgRuns, kind: .msg) {
                unresolvedIRs.append(
                    CollectedIR(
                        ir: message.parts[0], sourceLabel: message.sourceLabel,
                        topLevelTypeName: message.typeName, distros: message.distros))
            }
            for service in try mergeAcrossDistros(pkgRuns, kind: .srv) {
                for half in service.parts {
                    unresolvedIRs.append(
                        CollectedIR(
                            ir: half, sourceLabel: service.sourceLabel, topLevelTypeName: service.typeName,
                            distros: service.distros))
                }
                collectedServices.append(
                    ParsedService(
                        package: service.package, typeName: service.typeName, requestIDL: service.oldest.idl[0],
                        responseIDL: service.oldest.idl[1]))
            }
            for action in try mergeAcrossDistros(pkgRuns, kind: .action) {
                let actionIR = IRBuilder.action(
                    package: action.package, typeName: action.typeName, goal: action.parts[0],
                    result: action.parts[1], feedback: action.parts[2])
                // The user-defined Goal/Result/Feedback IRs go in the registry so wrapper
                // nested references resolve; the wrappers so the action-level hash and any
                // cross-package reference to a wrapper resolves.
                let parts = [
                    actionIR.goal, actionIR.result, actionIR.feedback,
                    actionIR.sendGoalRequest, actionIR.sendGoalResponse,
                    actionIR.getResultRequest, actionIR.getResultResponse,
                    actionIR.feedbackMessage,
                ]
                for ir in parts {
                    unresolvedIRs.append(
                        CollectedIR(
                            ir: ir, sourceLabel: action.sourceLabel, topLevelTypeName: action.typeName,
                            distros: action.distros))
                }
                collectedActions.append(
                    ParsedAction(package: action.package, typeName: action.typeName, actionIR: actionIR))
            }
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

    /// Multi-package generation. All inputs are parsed first, then the resulting IRs
    /// are aggregated into a registry. Hashing and emission run after the registry is
    /// complete so cross-package references (e.g. `std_msgs/Header → builtin_interfaces/Time`)
    /// resolve regardless of the order packages appear in `runs`.
    ///
    /// When two `runs` share the same `input.name` (typically because
    /// the caller passed both a Humble and a Jazzy directory for the same
    /// package), each message, service and action is generated once from the files of every
    /// distribution that has it: from the oldest one's when they build the same, else with
    /// each part (the message; the request and the response of a service; or the goal, the
    /// result and the feedback of an action) merged as ``IRBuilder/build(perDistro:kind:)``
    /// merges it into a distro-conditional IR. A type that cannot be merged throws
    /// ``GeneratorError/parse(_:)`` at the IDL file and line of the distribution that
    /// introduces the problem.
    public static func generateMulti(
        _ runs: [PackageRun],
        moduleNames: ModuleNames = [:]
    ) throws -> [GeneratedFile] {
        let c = try collect(runs)
        // Every type gets the hash of every modern distribution, projected onto it: each type in
        // the registry takes its own shape for that distribution (its schema distribution when
        // it was not read for it), as generated code encodes it. A type that reaches a varying
        // type (at any depth, across packages, even one read for more distributions than the
        // type itself) varies as well; equal hashes collapse into one `typeInfo`. Humble has no
        // RIHS01 and never gets a key, so a type that only differs on Humble keeps one hash.
        var hashesByRosName: [String: [String: String]] = [:]
        for entry in c.unresolvedIRs {
            var hashes: [String: String] = [:]
            for distro in IRBuilder.modernDistros {
                hashes[distro] = RIHS01.hash(entry.ir, for: distro, registry: c.registry)
            }
            hashesByRosName[entry.ir.rosTypeName] = hashes
        }
        var results: [GeneratedFile] = []
        for entry in c.unresolvedIRs {
            guard let hashes = hashesByRosName[entry.ir.rosTypeName] else {
                preconditionFailure(
                    "Pipeline: missing precomputed hash for \(entry.ir.rosTypeName)"
                )
            }
            let hashed = MessageIR(
                package: entry.ir.package,
                typeName: entry.ir.typeName,
                kind: entry.ir.kind,
                fields: entry.ir.fields,
                constants: entry.ir.constants,
                perDistroHashes: hashes.mapValues { Optional($0) },
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
        // One umbrella enum per parsed `.srv` so callers can use
        // `<Service>Srv.Request` / `.Response` and read the canonical service-level
        // hashes from `typeInfo`. The umbrella reuses the per-half hashes that
        // already landed in the registry above.
        for svc in c.collectedServices where !c.dependencyPackages.contains(svc.package) {
            let reqKey = "\(svc.package)/srv/\(svc.typeName)_Request"
            let resKey = "\(svc.package)/srv/\(svc.typeName)_Response"
            let serviceIR = ServiceDescription.serviceIR(
                package: svc.package, kind: .srv, serviceName: svc.typeName)
            var hashesByDistro: [String: ServiceHashes] = [:]
            for distro in IRBuilder.modernDistros {
                hashesByDistro[distro] = ServiceHashes(
                    requestHash: hashesByRosName[reqKey]?[distro],
                    responseHash: hashesByRosName[resKey]?[distro],
                    serviceHash: RIHS01.hash(serviceIR, for: distro, registry: c.registry))
            }
            let requestStructName = c.nameOverrides[reqKey] ?? "\(svc.typeName)Request"
            let responseStructName = c.nameOverrides[resKey] ?? "\(svc.typeName)Response"
            let umbrellaName = "\(svc.typeName)Srv"
            let umbrella = SwiftEmitter.emitServiceUmbrella(
                package: svc.package,
                serviceTypeName: svc.typeName,
                umbrellaName: umbrellaName,
                requestStructName: requestStructName,
                responseStructName: responseStructName,
                hashesByDistro: hashesByDistro,
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
        // One Swift file per parsed `.action`. Each file owns the
        // outer `<TypeName>Action` enum (with nested `Goal` / `Result` /
        // `Feedback`) plus the five sibling `<TypeName>_<Wrapper>` structs.
        // The action-level + wrapper hashes come from
        // ``IRBuilder/populateActionHashes(_:distro:extraRegistry:)``, once per modern
        // distribution, which reuses the global registry assembled above.
        for act in c.collectedActions where !c.dependencyPackages.contains(act.package) {
            var actionIR = act.actionIR
            for distro in IRBuilder.modernDistros {
                IRBuilder.populateActionHashes(&actionIR, distro: distro, extraRegistry: c.registry)
            }
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
        // Without Rolling IDL, generated types give Rolling the shape and hash of the newest
        // distribution read (the schema distribution rule).
        let emittedDistros = Set(runs.filter(\.emit).map(\.input.distro))
        let rollingStandIn = IRBuilder.schemaDistro(
            for: "rolling", read: emittedDistros.intersection(IRBuilder.distroOrder.filter { $0 != "rolling" }))
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

            /// One generated type: an ``OracleSample`` whose codecs take the message schemas of a
            /// distribution (nil: the default, Jazzy).
            struct OracleType {
                let rosName: String
                let distributions: Set<String>
                let encode: (ROS2Distro?) throws -> Data
                let reencode: (Data, ROS2Distro?) throws -> Data

                func sample(schema: ROS2Distro?) -> OracleSample {
                    OracleSample(
                        rosName: rosName, distributions: distributions, encode: { try encode(schema) },
                        reencode: { try reencode($0, schema) })
                }
            }

            /// The samples of this run.
            enum OracleSamples {
                /// Every distribution this run read IDL for.
                static let distributions: Set<String> = \(literal(emittedDistros))

                /// The samples of the types `distro` has, encoded and decoded with the message
                /// schemas of `distro`, or nil when this run read no IDL for `distro`. Without
                /// Rolling IDL, Rolling has the \(rollingStandIn.capitalized) samples: generated types give
                /// Rolling the \(rollingStandIn.capitalized) shape and hash.
                static func samples(for distro: String) -> [OracleSample]? {
                    let source = distro == "rolling" && !distributions.contains("rolling") ? "\(rollingStandIn)" : distro
                    guard distributions.contains(source) else { return nil }
                    let schema = ROS2Distro(rawValue: distro)
                    return types.filter { $0.distributions.contains(source) }.map { $0.sample(schema: schema) }
                }

                /// Every sample, in ROS-name order, with the default (Jazzy) schemas.
                static let all: [OracleSample] = types.map { $0.sample(schema: nil) }

                /// Every type, in ROS-name order.
                static let types: [OracleType] = [

            """
        for sample in samples.sorted(by: { $0.rosName < $1.rosName }) {
            registry += "        OracleType(\n"
            registry += "            rosName: \"\(sample.rosName)\",\n"
            registry += "            distributions: \(literal(sample.distros)),\n"
            registry += "            encode: { try oracleEncode(\(sample.swiftName).oracleSample(), $0) },\n"
            registry += "            reencode: { try oracleReencode(\(sample.swiftName).self, $0, $1) }),\n"
        }
        registry += """
                ]
            }

            func oracleEncode<T: CDREncodable>(_ value: T, _ schema: ROS2Distro?) throws -> Data {
                let encoder = schema.map { CDREncoder(distro: $0) } ?? CDREncoder()
                encoder.writeEncapsulationHeader()
                try value.encode(to: encoder)
                return encoder.getData()
            }

            func oracleReencode<T: CDRCodable>(_ type: T.Type, _ data: Data, _ schema: ROS2Distro?) throws -> Data {
                let decoder = try schema.map { try CDRDecoder(data: data, distro: $0) } ?? CDRDecoder(data: data)
                return try oracleEncode(T(from: decoder), schema)
            }

            """
        files.append(GeneratedFile(relativePath: "OracleSamples.swift", contents: registry))
        return files
    }

    /// Lightweight carrier for an as-parsed `.srv`: the two halves' IDLFiles (of the oldest
    /// distribution that has the service). The request / response halves, merged across
    /// distributions when they differ, are emitted via the regular message emission path; the
    /// umbrella enum is emitted from this carrier.
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
    ///
    /// Pass every distribution the generated code was made from, so the plan checks the merged
    /// projection the generated types carry, and select the distributions to check with
    /// `distros` (default: every distribution of the emitted runs except Humble). Each type is
    /// checked on every selected distribution with the hash its generated `typeInfo(for:)`
    /// returns there (the same projection). A distribution the type's package was read for but
    /// whose IDL lacks the type is skipped; a distribution the package was not read for
    /// (Rolling without Rolling IDL, or a distribution only other packages were read for) is
    /// checked when the type's schema distribution there (``IRBuilder/schemaDistro(for:read:)``
    /// over the package's distributions) has it, labelled with the selected distribution.
    public static func buildVerifyPlan(
        _ runs: [PackageRun],
        distros allowedDistros: Set<String>? = nil
    ) throws -> [VerifyPlanEntry] {
        // Reuse the multi-package gather + register sequence of generateMulti so
        // cross-package nested references resolve.
        let c = try collect(runs)
        // A selected distribution the type's package was not read for is checked as the
        // generated code treats it: the type of its schema distribution, with the hash projected
        // onto the selected distribution (each contained type with its own read set, exactly as
        // `generateMulti` computes the `typeInfo(for:)` ladder), labelled with the selected
        // distribution so the oracle JSON comes from that distribution's install.
        var packageDistros: [String: Set<String>] = [:]
        for run in runs { packageDistros[run.input.name, default: []].insert(run.input.distro) }
        let selected = (allowedDistros ?? Set(runs.filter(\.emit).map(\.input.distro))).filter { $0 != "humble" }
        func verifiedDistros(_ typeDistros: Set<String>, package: String) -> [String] {
            let read = packageDistros[package] ?? typeDistros
            return selected.filter { distro in
                if typeDistros.contains(distro) { return true }
                // The package was read for `distro` and its IDL there has no such type.
                if read.contains(distro) { return false }
                return typeDistros.contains(IRBuilder.schemaDistro(for: distro, read: read))
            }.sorted()
        }

        // For each selected distro compute the per-distro hash and emit one VerifyPlanEntry per
        // (ir, distro) pair, following ``CollectedIR/distros`` as above.
        var out: [VerifyPlanEntry] = []
        for entry in c.unresolvedIRs {
            // Humble does not have a hash oracle; rosidl pre-RIHS01. It is skipped silently to
            // keep the verify-mode focused on the distros the rosidl `.json` files exist for.
            for distro in verifiedDistros(entry.distros, package: entry.ir.package) {
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
            for distro in verifiedDistros(irDistros, package: ir.package) {
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
    /// Runs a parser call, reporting a ``ParseError`` as ``GeneratorError/parse(_:)``.
    private static func parse<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as ParseError {
            throw GeneratorError.parse(error)
        }
    }

    private static func validateAllReferencesResolved(registry: [String: MessageIR]) throws {
        for (_, ir) in registry {
            for field in ir.fields {
                guard let target = elementNestedReference(of: field.type) else { continue }
                // A nested reference may resolve under msg, srv, or
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
        try interfaceSources(of: run, kind: .action, allowList: run.typesAllowList).map { typeName, source in
            ParsedAction(
                package: run.input.name, typeName: typeName,
                actionIR: IRBuilder.action(
                    package: run.input.name, typeName: typeName, goal: source.ir[0], result: source.ir[1],
                    feedback: source.ir[2]))
        }
    }
}

extension Pipeline {
    /// One `.msg`, `.srv` or `.action` file of one distribution: its path and its parts (the
    /// message; the request and the response; or the goal, the result and the feedback), as
    /// parsed and as built on their own, so that an invalid default or constant is reported
    /// with the file and line it comes from.
    struct InterfaceSource {
        let path: String
        let idl: [IDLFile]
        let ir: [MessageIR]

        /// Whether `other` has the same parts, as parsed, apart from the lines they were
        /// written on. Comments and layout never reach the parsed IDL; nothing is compared as a
        /// number, so a default such as `nan` or `-0.0` is the same as itself and different from
        /// `0.0`.
        func sameParts(as other: InterfaceSource) -> Bool {
            idl.count == other.idl.count && zip(idl, other.idl).allSatisfy { $0.0.sameDeclarations(as: $0.1) }
        }
    }

    /// One message, service or action of a package, from the files of the distributions that
    /// have it.
    struct InterfaceType {
        let package: String
        let typeName: String
        let kind: MessageKind
        /// The distributions whose IDL has the type.
        let distros: Set<String>
        /// The file of the oldest of `distros`.
        let oldest: InterfaceSource
        /// The parts, in file order: those of `oldest` when every distribution builds them the
        /// same, else each part merged across `distros`.
        let parts: [MessageIR]

        /// The `// Source:` label of the type's generated files.
        var sourceLabel: String { Pipeline.sourceLabel(package: package, typeName: typeName, kind: kind) }
    }

    /// How merge errors name a type of `kind` (`message`, `service`, `action`) and its parts,
    /// in file order: a message is its only part and has no name.
    static func mergeErrorNames(_ kind: MessageKind) -> (type: String, parts: [String]) {
        switch kind {
        case .msg: return ("message", [""])
        case .srv: return ("service", ["request", "response"])
        case .action: return ("action", ["goal", "result", "feedback"])
        }
    }

    /// The `.msg`, `.srv` or `.action` files (by `kind`) of `run` whose type name passes
    /// `allowList`, sorted by file name, each with its type name, parsed and built.
    private static func interfaceSources(
        of run: PackageRun, kind: MessageKind, allowList: Set<String>?
    ) throws -> [(typeName: String, source: InterfaceSource)] {
        let package = run.input.name
        return try idlSources(of: run, kind: kind, allowList: allowList).map { file in
            let path = file.url.path
            let idl = try parse { () -> [IDLFile] in
                switch kind {
                case .msg:
                    return [
                        try Parser.parseMessage(
                            source: file.contents, file: path, package: package, typeName: file.typeName)
                    ]
                case .srv:
                    let service = try Parser.parseService(
                        source: file.contents, file: path, package: package, typeName: file.typeName)
                    return [service.request, service.response]
                case .action:
                    let action = try Parser.parseAction(
                        source: file.contents, file: path, package: package, typeName: file.typeName)
                    return [action.goal, action.result, action.feedback]
                }
            }
            let ir = try buildIR(file: path) { try idl.map { try IRBuilder.build(jazzy: $0, kind: kind) } }
            return (file.typeName, InterfaceSource(path: path, idl: idl, ir: ir))
        }
    }

    /// The messages, services or actions (by `kind`) of every run of one package, in
    /// first-seen order, each from the files of the distributions that have it. A type whose
    /// files build the same in every distribution is the type of the oldest of them, exactly as
    /// from a single distribution. One that differs has each part merged with
    /// ``IRBuilder/build(perDistro:kind:)``, so a field that only some distributions have is
    /// distro-conditional, and checked for fields that skip a distribution
    /// (``distroGap(in:readDistros:)``).
    ///
    /// A type takes part when any run's allow-list has it. The CLI gives every run the same
    /// `--types` filter.
    ///
    /// - Throws: ``GeneratorError/parse(_:)`` at the file and line of the distribution that
    ///   introduces the problem when a type cannot be merged: a field changes type (with its
    ///   type in every distribution), shared fields change order, or a field skips a
    ///   distribution.
    static func mergeAcrossDistros(_ runs: [PackageRun], kind: MessageKind) throws -> [InterfaceType] {
        var allowList: Set<String>? = nil
        for run in runs {
            if let allow = run.typesAllowList { allowList = (allowList ?? []).union(allow) }
        }
        var sourcesByName: [String: [String: InterfaceSource]] = [:]
        var order: [String] = []
        for run in runs {
            for (name, source) in try interfaceSources(of: run, kind: kind, allowList: allowList) {
                if sourcesByName[name] == nil { order.append(name) }
                sourcesByName[name, default: [:]][run.input.distro] = source
            }
        }
        return try order.map { try merge($0, kind: kind, sources: sourcesByName[$0]!) }
    }

    /// The type `typeName` of `kind` from the file of each distribution that has it; see
    /// ``mergeAcrossDistros(_:kind:)``.
    private static func merge(
        _ typeName: String, kind: MessageKind, sources: [String: InterfaceSource]
    ) throws -> InterfaceType {
        let oldestDistro = IRBuilder.oldestDistro(in: sources.keys)
        let oldest = sources[oldestDistro]!
        let package = oldest.idl[0].package
        func type(_ parts: [MessageIR]) -> InterfaceType {
            InterfaceType(
                package: package, typeName: typeName, kind: kind, distros: Set(sources.keys), oldest: oldest,
                parts: parts)
        }
        if sources.values.allSatisfy({ $0.sameParts(as: oldest) }) {
            return type(oldest.ir)
        }
        let label = sourceLabel(package: package, typeName: typeName, kind: kind)
        let names = mergeErrorNames(kind)
        // `<kind> '<Type>' cannot be merged across distributions: <part> <detail>`, at `line` of
        // the file of `distro`.
        func failure(_ part: Int, _ detail: String, in distro: String?, line: Int) -> GeneratorError {
            let name = names.parts[part]
            return .parse(
                ParseError(
                    file: distro.map { sources[$0]!.path } ?? label, line: line,
                    message:
                        "\(names.type) '\(typeName)' cannot be merged across distributions: \(name.isEmpty ? "" : "\(name) ")\(detail)"
                ))
        }
        // The line of field `field` of `part` in the file of `distro`.
        func line(of field: String, _ part: Int, in distro: String) -> Int {
            sources[distro]!.idl[part].fields.first { $0.name == field }?.sourceLine ?? 1
        }

        var parts: [MessageIR] = []
        for part in oldest.idl.indices {
            do {
                parts.append(
                    try buildIR(file: label) {
                        try IRBuilder.merge(perDistro: sources.mapValues { $0.idl[part] }, kind: kind)
                    })
            } catch let error as IRMergeError {
                guard case .conflictingFieldType(let field, let perDistroTypes) = error.kind else {
                    throw failure(part, "\(error)", in: nil, line: 1)
                }
                // The distributions that have the field, grouped by its type in order of appearance.
                var groups: [(type: FieldType, distros: [String])] = []
                for distro in IRBuilder.distroOrder {
                    guard let type = perDistroTypes[distro] else { continue }
                    if let i = groups.firstIndex(where: { $0.type == type }) {
                        groups[i].distros.append(distro)
                    } else {
                        groups.append((type, [distro]))
                    }
                }
                let changed = groups.count > 1 ? groups[1].distros[0] : groups[0].distros[0]
                let types = groups.map { "\(idlName($0.type)) in [\($0.distros.joined(separator: ", "))]" }
                throw failure(
                    part, "field '\(field)' changes type: \(types.joined(separator: ", "))", in: changed,
                    line: line(of: field, part, in: changed))
            } catch let error as FieldOrderError {
                throw failure(part, error.detail, in: error.distro, line: line(of: error.field, part, in: error.distro))
            }
        }
        for (part, ir) in parts.enumerated() {
            guard let gap = distroGap(in: ir, readDistros: Set(sources.keys)) else { continue }
            // The distribution that has the field again after the gap.
            let back = gap.presentIn.first {
                IRBuilder.distroOrder.firstIndex(of: $0)! > IRBuilder.distroOrder.firstIndex(of: gap.missingFrom[0])!
            }!
            func list(_ distros: [String]) -> String { "[" + distros.joined(separator: ", ") + "]" }
            throw failure(
                part,
                "field '\(gap.field)' exists in \(list(gap.presentIn)) but not in \(list(gap.missingFrom)) between them — a field must exist in one contiguous run of distributions",
                in: back, line: line(of: gap.field, part, in: back))
        }
        return type(parts)
    }

    /// `type` as an IDL file writes it: `int32`, `string<=8`, `geometry_msgs/Pose[3]`.
    private static func idlName(_ type: FieldType) -> String {
        switch type {
        case .primitive(let primitive):
            return primitive.rawValue
        case .nested(let package, let typeName):
            return "\(package)/\(typeName)"
        case .array(let element, let length):
            return "\(idlName(element))[\(length)]"
        case .sequence(let element, let upperBound):
            return "\(idlName(element))[\(upperBound.map { "<=\($0)" } ?? "")]"
        case .boundedString(let isWide, let upperBound):
            return "\(isWide ? "wstring" : "string")<=\(upperBound)"
        }
    }
}
