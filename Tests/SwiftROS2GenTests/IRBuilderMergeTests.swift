import Testing

@testable import SwiftROS2Gen

@Suite("IRBuilder.build(perDistro:)")
struct IRBuilderMergeTests {
    /// Build an `IDLFile` containing the given primitive fields in source order.
    private func makeIDL(
        package: String,
        typeName: String,
        primitives: [(String, PrimitiveType)]
    ) -> IDLFile {
        let fields = primitives.enumerated().map { index, pair in
            IDLField(name: pair.0, type: .primitive(pair.1), sourceLine: index + 1)
        }
        return IDLFile(package: package, typeName: typeName, fields: fields)
    }

    @Test("field added in later distro is .onlyIn that distro and its successors")
    func fieldAddedInLaterDistro() throws {
        let humble = makeIDL(
            package: "sensor_msgs", typeName: "Range",
            primitives: [
                ("min_range", .float32), ("max_range", .float32), ("range", .float32),
            ])
        let jazzy = makeIDL(
            package: "sensor_msgs", typeName: "Range",
            primitives: [
                ("min_range", .float32), ("max_range", .float32), ("range", .float32),
                ("variance", .float32),
            ])
        let ir = try IRBuilder.build(perDistro: ["humble": humble, "jazzy": jazzy])
        #expect(ir.fields.count == 4)
        #expect(ir.fields.map(\.ros2Name) == ["min_range", "max_range", "range", "variance"])
        for i in 0..<3 {
            #expect(ir.fields[i].availability == .all, "field \(ir.fields[i].ros2Name)")
        }
        #expect(ir.fields[3].availability == .onlyIn(["jazzy"]))
        #expect(ir.perDistroFieldPresence["humble"] == ["min_range", "max_range", "range"])
        #expect(ir.perDistroFieldPresence["jazzy"]?.count == 4)
    }

    @Test("field removed in later distro is .onlyIn earlier distro")
    func fieldRemovedInLaterDistro() throws {
        let humble = makeIDL(
            package: "demo_msgs", typeName: "Foo",
            primitives: [("a", .int32), ("legacy", .int32), ("b", .int32)])
        let jazzy = makeIDL(
            package: "demo_msgs", typeName: "Foo",
            primitives: [("a", .int32), ("b", .int32)])
        let ir = try IRBuilder.build(perDistro: ["humble": humble, "jazzy": jazzy])
        #expect(ir.fields.map(\.ros2Name) == ["a", "legacy", "b"])
        #expect(ir.fields[0].availability == .all)
        #expect(ir.fields[1].availability == .onlyIn(["humble"]))
        #expect(ir.fields[2].availability == .all)
    }

    @Test("breaking type change throws conflictingFieldType")
    func breakingTypeChangeThrows() {
        let humble = makeIDL(
            package: "demo_msgs", typeName: "Foo",
            primitives: [("payload", .int32)])
        let jazzy = makeIDL(
            package: "demo_msgs", typeName: "Foo",
            primitives: [("payload", .int64)])
        do {
            _ = try IRBuilder.build(perDistro: ["humble": humble, "jazzy": jazzy])
            Issue.record("expected IRMergeError")
        } catch let error as IRMergeError {
            switch error.kind {
            case .conflictingFieldType(let name, let perDistroTypes):
                #expect(name == "payload")
                #expect(perDistroTypes["humble"] == .primitive(.int32))
                #expect(perDistroTypes["jazzy"] == .primitive(.int64))
            default:
                Issue.record("expected .conflictingFieldType, got \(error.kind)")
            }
        } catch {
            Issue.record("expected IRMergeError, got \(error)")
        }
    }

    @Test("fields reordered between distros are rejected")
    func reorderedFieldsAreRejected() {
        let humble = makeIDL(
            package: "demo_msgs", typeName: "Foo",
            primitives: [("a", .int32), ("b", .int32)])
        let jazzy = makeIDL(
            package: "demo_msgs", typeName: "Foo",
            primitives: [("b", .int32), ("a", .int32)])
        #expect(
            throws: IRBuildError("demo_msgs/msg/Foo: fields 'a', 'b' are in a different order in jazzy than in humble")
        ) {
            try IRBuilder.build(perDistro: ["humble": humble, "jazzy": jazzy])
        }
    }

    @Test("a field inserted in the middle in a later distro keeps every distro's order")
    func fieldInsertedInTheMiddle() throws {
        let jazzy = makeIDL(
            package: "demo_msgs", typeName: "Foo",
            primitives: [("a", .int32), ("b", .int32), ("c", .int32)])
        let lyrical = makeIDL(
            package: "demo_msgs", typeName: "Foo",
            primitives: [("a", .int32), ("x", .float64), ("b", .int32), ("c", .int32)])
        let ir = try IRBuilder.build(perDistro: ["jazzy": jazzy, "lyrical": lyrical])
        #expect(ir.fields.map(\.ros2Name) == ["a", "x", "b", "c"])
        #expect(ir.fields[1].availability == .onlyIn(["lyrical"]))
        #expect(ir.fields.filter { $0.ros2Name != "x" }.allSatisfy { $0.availability == .all })
    }

    @Test("a field one distro drops and another adds at the same place follows the older order")
    func droppedAndAddedFieldsFollowTheOlderOrder() throws {
        let jazzy = makeIDL(
            package: "demo_msgs", typeName: "Foo",
            primitives: [("a", .int32), ("old", .int32), ("c", .int32)])
        let kilted = makeIDL(
            package: "demo_msgs", typeName: "Foo",
            primitives: [("a", .int32), ("new", .int32), ("c", .int32)])
        let ir = try IRBuilder.build(perDistro: ["jazzy": jazzy, "kilted": kilted])
        #expect(ir.fields.map(\.ros2Name) == ["a", "old", "new", "c"])
    }

    @Test("an order only a later distro fixes is taken from that distro")
    func laterDistroFixesTheOrder() throws {
        // Jazzy and Kilted leave the order of 'b' and 'x' open; Lyrical has both.
        let jazzy = makeIDL(
            package: "demo_msgs", typeName: "Foo",
            primitives: [("a", .int32), ("b", .int32), ("c", .int32)])
        let kilted = makeIDL(
            package: "demo_msgs", typeName: "Foo",
            primitives: [("a", .int32), ("x", .int32), ("c", .int32)])
        let lyrical = makeIDL(
            package: "demo_msgs", typeName: "Foo",
            primitives: [("a", .int32), ("b", .int32), ("x", .int32), ("c", .int32)])
        let ir = try IRBuilder.build(perDistro: ["jazzy": jazzy, "kilted": kilted, "lyrical": lyrical])
        #expect(ir.fields.map(\.ros2Name) == ["a", "b", "x", "c"])
    }

    @Test("fields no single order fits are rejected even when no two distros disagree directly")
    func cyclicOrderIsRejected() {
        let jazzy = makeIDL(
            package: "demo_msgs", typeName: "Foo", primitives: [("a", .int32), ("b", .int32)])
        let kilted = makeIDL(
            package: "demo_msgs", typeName: "Foo", primitives: [("b", .int32), ("c", .int32)])
        let lyrical = makeIDL(
            package: "demo_msgs", typeName: "Foo", primitives: [("c", .int32), ("a", .int32)])
        #expect(
            throws: IRBuildError(
                "demo_msgs/msg/Foo: fields 'a', 'b', 'c' cannot be put in one order that matches every distribution")
        ) {
            try IRBuilder.build(perDistro: ["jazzy": jazzy, "kilted": kilted, "lyrical": lyrical])
        }
    }
}
