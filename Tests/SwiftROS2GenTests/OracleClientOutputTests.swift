import Foundation
import Testing

@testable import SwiftROS2Gen

/// The hash oracle reads each `<Type>.json` from `docker run … cat`. A closure such as
/// moveit_msgs/action/MoveGroup writes files far larger than a pipe buffer, which hung the
/// verifier when it waited for the process before reading its output.
@Suite("Oracle client output")
struct OracleClientOutputTests {

    #if os(macOS) || os(Linux)
        @Test("Output larger than a pipe buffer is read in full")
        func readsOutputLargerThanAPipeBuffer() throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            // 512 KiB on stdout and 128 KiB on stderr, both beyond a 64 KiB pipe buffer.
            process.arguments = [
                "-c", "head -c 524288 /dev/zero | tr '\\0' a; head -c 131072 /dev/zero | tr '\\0' b >&2",
            ]
            let output = try OracleClient.runCollectingOutput(process)
            #expect(output.status == 0)
            #expect(output.stdout.count == 524_288)
            #expect(output.stderr.count == 131_072)
            #expect(output.stdout.allSatisfy { $0 == UInt8(ascii: "a") })
        }

        @Test("A non-zero exit status is reported with stderr")
        func reportsExitStatusAndStderr() throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "echo missing >&2; exit 3"]
            let output = try OracleClient.runCollectingOutput(process)
            #expect(output.status == 3)
            #expect(String(data: output.stderr, encoding: .utf8) == "missing\n")
            #expect(output.stdout.isEmpty)
        }
    #endif
}
