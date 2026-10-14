import Testing

@testable import SwiftROS2Gen

@Suite("Generated file imports")
struct ModuleImportsTests {
    @Test("imports SwiftROS2Messages and every referenced package, never its own")
    func importsReferencedPackages() {
        let fields: [FieldType] = [
            .nested(package: "std_msgs", typeName: "Header"),
            .sequence(element: .nested(package: "geometry_msgs", typeName: "Pose"), upperBound: nil),
            .array(element: .nested(package: "nav_msgs", typeName: "MapMetaData"), length: 2),
            .primitive(.float64),
        ]
        let imports = ModuleImports.imports(
            ownPackage: "nav_msgs", fieldTypes: fields, moduleNames: [:], extraImports: [])
        #expect(imports == ["GeometryMsgs", "StdMsgs", "SwiftROS2Messages"])
    }

    @Test("extra imports join the derived ones, sorted and without duplicates")
    func extraImportsDeduplicated() {
        let imports = ModuleImports.imports(
            ownPackage: "my_msgs",
            fieldTypes: [.nested(package: "std_msgs", typeName: "Header")],
            moduleNames: [:],
            extraImports: ["StdMsgs", "SwiftROS2Messages", "MyHelpers"])
        #expect(imports == ["MyHelpers", "StdMsgs", "SwiftROS2Messages"])
    }

    @Test("packages mapped to the file's own module are not imported")
    func moduleMapCollapsesPackages() {
        let names: ModuleNames = ["std_msgs": "Fixtures", "sensor_msgs": "Fixtures"]
        let imports = ModuleImports.imports(
            ownPackage: "sensor_msgs",
            fieldTypes: [.nested(package: "std_msgs", typeName: "Header")],
            moduleNames: names, extraImports: [])
        #expect(imports == ["SwiftROS2Messages"])
    }

    @Test("module names PascalCase the package, digits included")
    func moduleNameForPackage() {
        #expect(ModuleImports.moduleName(forPackage: "tf2_msgs", moduleNames: [:]) == "Tf2Msgs")
        #expect(
            ModuleImports.moduleName(forPackage: "example_interfaces", moduleNames: ["example_interfaces": "X"])
                == "X")
    }

    @Test("emitted Header imports BuiltinInterfaces and no longer SwiftROS2Wire")
    func emittedHeaderImports() {
        let ir = MessageIR(
            package: "std_msgs", typeName: "Header",
            fields: [
                FieldIR(
                    ros2Name: "stamp", swiftName: "stamp",
                    type: .nested(package: "builtin_interfaces", typeName: "Time"), availability: .all),
                FieldIR(ros2Name: "frame_id", swiftName: "frameId", type: .primitive(.string), availability: .all),
            ],
            perDistroHashes: ["jazzy": "RIHS01_x"])
        let out = SwiftEmitter.emit(ir, sourceLabel: "test")
        #expect(out.contains("import BuiltinInterfaces\nimport SwiftROS2CDR\nimport SwiftROS2Messages\n"))
        #expect(!out.contains("SwiftROS2Wire"))
    }
}
