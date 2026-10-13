import Foundation
import Testing

@testable import SwiftROS2Gen

@Suite("Package input parsing")
struct PackageInputParsingTests {
    @Test("a well-formed value yields the package, directory and distro")
    func wellFormed() throws {
        let input = try PackageInput.parse("std_msgs=/idl/std_msgs@jazzy", option: "--input")
        #expect(input.name == "std_msgs")
        #expect(input.directory.path == "/idl/std_msgs")
        #expect(input.distro == "jazzy")
    }

    @Test("a malformed --dependency value is reported as --dependency")
    func malformedDependencyNamesTheOption() {
        #expect(
            throws: PackageInputFormatError(
                description: "malformed --dependency 'std_msgs' (expected '<package>=<path>@<distro>')")
        ) {
            try PackageInput.parse("std_msgs", option: "--dependency")
        }
        #expect(
            throws: PackageInputFormatError(
                description: "malformed --dependency 'std_msgs=/idl/std_msgs' (missing '@<distro>')")
        ) {
            try PackageInput.parse("std_msgs=/idl/std_msgs", option: "--dependency")
        }
    }

    @Test("a malformed --input value is reported as --input")
    func malformedInputNamesTheOption() {
        #expect(
            throws: PackageInputFormatError(
                description: "malformed --input 'std_msgs=/idl/std_msgs' (missing '@<distro>')")
        ) {
            try PackageInput.parse("std_msgs=/idl/std_msgs", option: "--input")
        }
    }
}
