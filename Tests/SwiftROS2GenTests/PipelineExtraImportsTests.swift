import Foundation
import Testing

@testable import SwiftROS2Gen

/// Phase 7 plumbing: ``Pipeline.generate(_:)`` and
/// ``Pipeline.generateMulti(_:)`` accept an `extraImports` array that the
/// emitter merges into every generated Swift file's import block, together
/// with the derived imports (`SwiftROS2Messages` and the module of every
/// referenced package).
@Suite("Pipeline extraImports plumbing")
struct PipelineExtraImportsTests {
    @Test("extraImports is reflected in every emitted file (single-package path)")
    func extraImportsAppearInSinglePackageOutput() throws {
        let fixtureURL = try #require(
            Bundle.module.url(
                forResource: "std_msgs_primitives", withExtension: nil,
                subdirectory: "Resources/IDL"))
        let files = try Pipeline.generate(
            for: PackageInput(name: "std_msgs", directory: fixtureURL),
            extraImports: ["SwiftROS2Messages"])
        #expect(!files.isEmpty)
        for file in files {
            #expect(
                file.contents.contains("\nimport SwiftROS2Messages\n"),
                "expected `import SwiftROS2Messages` in \(file.relativePath)")
        }
    }

    @Test("extraImports is reflected in every emitted file (multi-package path)")
    func extraImportsAppearInMultiPackageOutput() throws {
        let fixtureURL = try #require(
            Bundle.module.url(
                forResource: "std_msgs_primitives", withExtension: nil,
                subdirectory: "Resources/IDL"))
        let files = try Pipeline.generateMulti(
            [.init(input: PackageInput(name: "std_msgs", directory: fixtureURL))],
            extraImports: ["SwiftROS2Messages"])
        #expect(!files.isEmpty)
        for file in files {
            #expect(
                file.contents.contains("\nimport SwiftROS2Messages\n"),
                "expected `import SwiftROS2Messages` in \(file.relativePath)")
        }
    }

    @Test("default empty extraImports imports only SwiftROS2CDR and SwiftROS2Messages")
    func defaultImportsAreCDRAndProtocols() throws {
        let fixtureURL = try #require(
            Bundle.module.url(
                forResource: "std_msgs_primitives", withExtension: nil,
                subdirectory: "Resources/IDL"))
        let files = try Pipeline.generate(
            for: PackageInput(name: "std_msgs", directory: fixtureURL))
        for file in files {
            let imports = file.contents.split(separator: "\n").filter { $0.hasPrefix("import ") }
            #expect(imports == ["import SwiftROS2CDR", "import SwiftROS2Messages"], "\(file.relativePath)")
        }
    }

    @Test("Pipeline.generate rejects an extraImport that is not a module identifier")
    func generateRejectsInvalidExtraImport() throws {
        let fixtureURL = try #require(
            Bundle.module.url(
                forResource: "std_msgs_primitives", withExtension: nil,
                subdirectory: "Resources/IDL"))
        #expect(throws: GeneratorError.self) {
            _ = try Pipeline.generate(
                for: PackageInput(name: "std_msgs", directory: fixtureURL),
                extraImports: ["Foundation\nimport Bad"])
        }
    }

    @Test("Pipeline.generateMulti rejects an extraImport that is not a module identifier")
    func generateMultiRejectsInvalidExtraImport() throws {
        let fixtureURL = try #require(
            Bundle.module.url(
                forResource: "std_msgs_primitives", withExtension: nil,
                subdirectory: "Resources/IDL"))
        #expect(throws: GeneratorError.self) {
            _ = try Pipeline.generateMulti(
                [.init(input: PackageInput(name: "std_msgs", directory: fixtureURL))],
                extraImports: [" SwiftROS2Messages "])
        }
    }
}

@Suite("ModuleIdentifier validation")
struct ModuleIdentifierTests {
    @Test("accepts simple module identifiers")
    func acceptsSimpleIdentifiers() {
        #expect(ModuleIdentifier.isValid("Foundation"))
        #expect(ModuleIdentifier.isValid("SwiftROS2Messages"))
        #expect(ModuleIdentifier.isValid("_Internal"))
        #expect(ModuleIdentifier.isValid("a"))
        #expect(ModuleIdentifier.isValid("Module2"))
    }

    @Test("accepts dotted module identifiers")
    func acceptsDottedIdentifiers() {
        #expect(ModuleIdentifier.isValid("Foo.Bar"))
        #expect(ModuleIdentifier.isValid("My.Nested.Module"))
    }

    @Test("rejects empty and whitespace-only inputs")
    func rejectsEmptyAndWhitespace() {
        #expect(!ModuleIdentifier.isValid(""))
        #expect(!ModuleIdentifier.isValid(" "))
        #expect(!ModuleIdentifier.isValid("Foundation "))
        #expect(!ModuleIdentifier.isValid(" Foundation"))
    }

    @Test("rejects identifiers starting with a digit")
    func rejectsLeadingDigit() {
        #expect(!ModuleIdentifier.isValid("2Module"))
        #expect(!ModuleIdentifier.isValid("Foo.2Bar"))
    }

    @Test("rejects punctuation and quoting")
    func rejectsPunctuation() {
        #expect(!ModuleIdentifier.isValid("Foundation;import Evil"))
        #expect(!ModuleIdentifier.isValid("Foundation\""))
        #expect(!ModuleIdentifier.isValid("Foundation,Bar"))
        #expect(!ModuleIdentifier.isValid("Foo-Bar"))
    }

    @Test("rejects newlines that would break out of the import line")
    func rejectsNewlines() {
        #expect(!ModuleIdentifier.isValid("Foundation\nimport Bad"))
        #expect(!ModuleIdentifier.isValid("Foundation\r\nimport Bad"))
    }

    @Test("rejects empty segments in dotted identifiers")
    func rejectsEmptyDottedSegments() {
        #expect(!ModuleIdentifier.isValid("."))
        #expect(!ModuleIdentifier.isValid("Foo."))
        #expect(!ModuleIdentifier.isValid(".Bar"))
        #expect(!ModuleIdentifier.isValid("Foo..Bar"))
    }
}
