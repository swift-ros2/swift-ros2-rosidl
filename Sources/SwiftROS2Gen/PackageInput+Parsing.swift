import Foundation

/// A command-line package value that is not of the form `<package>=<path>@<distro>`.
public struct PackageInputFormatError: Error, Equatable, CustomStringConvertible {
    /// What is wrong with the value, naming the option it was passed to.
    public let description: String

    /// Creates an error with the given message.
    public init(description: String) {
        self.description = description
    }
}

extension PackageInput {
    /// Parses a `<package>=<path>@<distro>` command-line value.
    ///
    /// - Parameters:
    ///   - raw: the value, e.g. `std_msgs=/idl/std_msgs@jazzy`.
    ///   - option: the option the value was passed to (`--input`, `--dependency`), used in the
    ///     error message so a malformed value is reported against the option that carried it.
    /// - Throws: ``PackageInputFormatError`` when the `=` or the `@<distro>` part is missing.
    public static func parse(_ raw: String, option: String) throws -> PackageInput {
        let eqParts = raw.split(separator: "=", maxSplits: 1).map(String.init)
        guard eqParts.count == 2 else {
            throw PackageInputFormatError(
                description: "malformed \(option) '\(raw)' (expected '<package>=<path>@<distro>')")
        }
        let atParts = eqParts[1].split(separator: "@", maxSplits: 1).map(String.init)
        guard atParts.count == 2 else {
            throw PackageInputFormatError(description: "malformed \(option) '\(raw)' (missing '@<distro>')")
        }
        return PackageInput(
            name: eqParts[0], directory: URL(fileURLWithPath: atParts[0], isDirectory: true),
            distro: atParts[1])
    }
}
