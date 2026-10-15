/// Swift module name per ROS package, overriding the PascalCase default.
public typealias ModuleNames = [String: String]

/// Computes the `import` list of a generated file.
///
/// Every generated file imports ``protocolsModule``, and every file that encodes or decodes a type
/// (all but service umbrellas) imports ``cdrModule``. A file also imports the
/// module of every other ROS package its fields reference.
/// Duplicates and the file's own module are dropped, and the list is sorted
/// lexicographically so generated files pass swift-format's `OrderedImports` rule.
public enum ModuleImports {
    /// The module that carries `ROS2Message`, the type-info structs and `ROS2Distro`.
    public static let protocolsModule = "SwiftROS2Messages"

    /// The module that carries the CDR encoder and decoder every generated file uses.
    public static let cdrModule = "SwiftROS2CDR"

    /// The Swift module for `package`: the override in `moduleNames`, else the package
    /// PascalCased (`tf2_msgs` → `Tf2Msgs`).
    public static func moduleName(forPackage package: String, moduleNames: ModuleNames) -> String {
        moduleNames[package] ?? Pipeline.pascal(package)
    }

    /// Imports for a file that defines a type of `ownPackage` whose fields have `fieldTypes`,
    /// excluding ``cdrModule``, sorted lexicographically.
    public static func imports(
        ownPackage: String,
        fieldTypes: [FieldType],
        moduleNames: ModuleNames
    ) -> [String] {
        let ownModule = moduleName(forPackage: ownPackage, moduleNames: moduleNames)
        var packages = Set<String>()
        for type in fieldTypes { packages.formUnion(type.referencedPackages) }
        var modules: Set<String> = [protocolsModule]
        for package in packages {
            modules.insert(moduleName(forPackage: package, moduleNames: moduleNames))
        }
        modules.remove(ownModule)
        modules.remove(cdrModule)
        return modules.sorted()
    }

    /// The `import` lines of a generated file: ``cdrModule`` plus ``imports(ownPackage:fieldTypes:moduleNames:)``,
    /// sorted lexicographically, one `import <Module>` per line.
    public static func importLines(
        ownPackage: String,
        fieldTypes: [FieldType],
        moduleNames: ModuleNames
    ) -> String {
        let modules = imports(ownPackage: ownPackage, fieldTypes: fieldTypes, moduleNames: moduleNames)
        return ([cdrModule] + modules).sorted().map { "import \($0)\n" }.joined()
    }

    /// Imports for a file outside every generated package (an oracle corpus) that uses types of
    /// `packages`: ``protocolsModule`` plus the module of every package, sorted lexicographically.
    public static func imports(referencing packages: Set<String>, moduleNames: ModuleNames) -> [String] {
        Set([protocolsModule] + packages.map { moduleName(forPackage: $0, moduleNames: moduleNames) }).sorted()
    }
}

extension FieldType {
    /// The ROS packages this field type references, looking through arrays and sequences.
    public var referencedPackages: Set<String> {
        switch self {
        case .nested(let package, _): return [package]
        case .array(let element, _), .sequence(let element, _): return element.referencedPackages
        case .primitive, .boundedString: return []
        }
    }

    /// ROS names (`<pkg>/msg/<Type>`) of the message types this field references, looking
    /// through arrays and sequences.
    public var referencedTypeNames: Set<String> {
        switch self {
        case .nested(let package, let typeName): return ["\(package)/msg/\(typeName)"]
        case .array(let element, _), .sequence(let element, _): return element.referencedTypeNames
        case .primitive, .boundedString: return []
        }
    }
}
