import Foundation

// Usage: RosidlOracleCorpus [<output-dir> [<distro>]]
//
// Checks that Swift decodes the CDR bytes of every generated sample and re-encodes them to the
// same bytes (the round-trip test of every generated type), then writes the bytes to
// <output-dir>/<rosName>.cdr (default output-dir: oracle-corpus) for the rclpy oracle
// (Scripts/cdr-oracle.py). With <distro>, it writes only the samples of the types that
// distribution has (rolling: the Lyrical set, unless Rolling IDL was generated), encoded with
// that distribution's message schemas, and round-trips them too; without it, every sample with
// the default (Jazzy) schemas. Exits 1 on any mismatch and 2 for a distribution no IDL was
// generated for.
let arguments = Array(CommandLine.arguments.dropFirst())
let output = URL(fileURLWithPath: arguments.first ?? "oracle-corpus", isDirectory: true)
var selected = OracleSamples.all
if arguments.count > 1 {
    let distro = arguments[1]
    guard let samples = OracleSamples.samples(for: distro) else {
        let known = OracleSamples.distributions.sorted().joined(separator: ", ")
        FileHandle.standardError.write(Data("no samples for '\(distro)': generated for \(known)\n".utf8))
        exit(2)
    }
    selected = samples
}
var failures: [String] = []
for sample in OracleSamples.all + (arguments.count > 1 ? selected : []) {
    let bytes = try sample.encode()
    do {
        if try sample.reencode(bytes) != bytes { failures.append(sample.rosName) }
    } catch {
        failures.append("\(sample.rosName) (\(error))")
    }
}
guard failures.isEmpty else {
    FileHandle.standardError.write(Data("Swift round-trip failed: \(failures.joined(separator: ", "))\n".utf8))
    exit(1)
}
for sample in selected {
    let file = output.appendingPathComponent(sample.rosName + ".cdr")
    try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try sample.encode().write(to: file)
}
print(
    "wrote \(selected.count) of \(OracleSamples.all.count) samples to \(output.path); all round-trip in Swift")
