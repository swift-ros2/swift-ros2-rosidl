import Foundation

// For every generated sample: checks that Swift decodes its CDR bytes and re-encodes them to
// the same bytes (the round-trip test of every generated type), then writes the bytes to
// <output>/<rosName>.cdr for the rclpy oracle (Scripts/cdr-oracle.py). Exits 1 on any mismatch.
let output = URL(
    fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "oracle-corpus", isDirectory: true)
var failures: [String] = []
for sample in OracleSamples.all {
    let bytes = try sample.encode()
    do {
        if try sample.reencode(bytes) != bytes { failures.append(sample.rosName) }
    } catch {
        failures.append("\(sample.rosName) (\(error))")
    }
    let file = output.appendingPathComponent(sample.rosName + ".cdr")
    try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try bytes.write(to: file)
}
guard failures.isEmpty else {
    FileHandle.standardError.write(Data("Swift round-trip failed: \(failures.joined(separator: ", "))\n".utf8))
    exit(1)
}
print("wrote \(OracleSamples.all.count) samples to \(output.path); all round-trip in Swift")
