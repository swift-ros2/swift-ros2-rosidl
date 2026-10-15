import Foundation
import Testing

@testable import SwiftROS2Gen

/// `SwiftROS2GenPlugin` declares the output file of every `.msg` before `swift-ros2-gen` runs, so
/// it copies the generator's naming rule. The plugin cannot be imported, so this reads its
/// source and compares its `Msg`-suffix table with the emitter's.
@Suite("SwiftROS2GenPlugin naming matches the generator")
struct PluginNamingTests {
    /// The string literals of the plugin's `collisionTypeNames` set.
    private static func pluginCollisionTypeNames() throws -> Set<String> {
        let pluginSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SwiftROS2GenTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
            .appendingPathComponent("Plugins/SwiftROS2GenPlugin/SwiftROS2GenPlugin.swift")
        let source = try String(contentsOf: pluginSource, encoding: .utf8)
        let declaration = try #require(source.range(of: "static let collisionTypeNames: Set<String> = ["))
        let end = try #require(source.range(of: "]", range: declaration.upperBound..<source.endIndex))
        let body = source[declaration.upperBound..<end.lowerBound]
        return Set(body.split(separator: "\"").enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) })
    }

    @Test("the plugin's Msg-suffix table is the emitter's")
    func collisionTablesMatch() throws {
        let plugin = try Self.pluginCollisionTypeNames()
        #expect(!plugin.isEmpty)
        #expect(plugin == SwiftEmitter.collisionTypeNames)
    }

    @Test("the plugin's file names are the ones generateMulti writes")
    func fileNamesMatchThePipeline() throws {
        let fixtureURL = try #require(
            Bundle.module.url(forResource: "std_msgs_primitives", withExtension: nil, subdirectory: "Resources/IDL"))
        let files = try Pipeline.generateMulti([.init(input: PackageInput(name: "std_msgs", directory: fixtureURL))])
        let plugin = try Self.pluginCollisionTypeNames()
        let msgDirectory = fixtureURL.appendingPathComponent("msg")
        let stems = try FileManager.default.contentsOfDirectory(atPath: msgDirectory.path)
            .filter { $0.hasSuffix(".msg") }
            .map { String($0.dropLast(".msg".count)) }
        // The plugin's rule: `<PascalPackage>/<Type>[Msg].swift`, with the Pipeline's PascalCase.
        let pluginPaths = Set(stems.map { "StdMsgs/\($0)\(plugin.contains($0) ? "Msg" : "").swift" })
        #expect(pluginPaths == Set(files.map(\.relativePath)))
    }
}
