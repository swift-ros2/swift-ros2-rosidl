import Testing

@testable import SwiftROS2Gen

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
