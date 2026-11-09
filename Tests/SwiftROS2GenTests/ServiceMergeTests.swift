import Foundation
import Testing

@testable import SwiftROS2Gen

/// A service whose `.srv` differs between distributions: its request and response are merged
/// like messages, and every distribution keeps the hashes of its own `.srv`, the service-level
/// and event hashes included.
@Suite("Services that differ between distributions")
struct ServiceMergeTests {
    /// ``MultiDistroFixture/probing`` read for `distros` only.
    static func probing(
        _ distros: Set<String> = ["humble", "jazzy", "kilted", "lyrical"]
    ) throws -> MultiDistroFixture {
        try MultiDistroFixture(MultiDistroFixture.probing.filter { distros.contains($0.key) })
    }

    /// The request, response and service-level hashes of `fixture_msgs/srv/Probe` that a run of
    /// ``MultiDistroFixture/probing`` read for `distro` alone has on `distro`.
    static func ownHashes(_ distro: String) throws -> ServiceHashes {
        let single = try probing([distro])
        defer { single.remove() }
        let hashes = try ActionMergeTests.hashes(single.runs, distro)
        return ServiceHashes(
            requestHash: hashes["fixture_msgs/srv/Probe_Request"],
            responseHash: hashes["fixture_msgs/srv/Probe_Response"], serviceHash: hashes["fixture_msgs/srv/Probe"])
    }

    @Test("the request and the response are merged like messages")
    func halvesAreMergedLikeMessages() throws {
        let fixture = try Self.probing()
        defer { fixture.remove() }
        let collected = try Pipeline.collect(fixture.runs)
        func half(_ name: String) throws -> MessageIR {
            try #require(collected.unresolvedIRs.first { $0.ir.rosTypeName == "fixture_msgs/srv/Probe_\(name)" }).ir
        }
        func availability(_ ir: MessageIR) -> [String: FieldAvailability] {
            Dictionary(uniqueKeysWithValues: ir.fields.map { ($0.ros2Name, $0.availability) })
        }
        let request = try half("Request")
        #expect(request.fields.map(\.ros2Name) == ["target", "legacy_mode", "tolerance"])
        #expect(
            availability(request) == [
                "target": .all, "legacy_mode": .onlyIn(["humble"]), "tolerance": .onlyIn(["kilted", "lyrical"]),
            ])
        // Lyrical's `success` comes before the shared `status`: each distribution reads its own.
        let response = try half("Response")
        #expect(response.fields.map(\.ros2Name) == ["success", "status"])
        #expect(availability(response) == ["success": .onlyIn(["lyrical"]), "status": .all])
        #expect(Set(response.perDistroFieldPresence.keys) == ["humble", "jazzy", "kilted", "lyrical"])

        // The constants are the union, in the order the distributions add them.
        #expect(response.constants.map(\.ros2Name) == ["OK", "BUSY"])
        #expect(response.constants.map(\.value) == [.uint(0), .uint(2)])
        #expect(request.constants.isEmpty)

        // Both halves have every distribution that has the service.
        for entry in collected.unresolvedIRs where entry.ir.package == "fixture_msgs" {
            #expect(entry.distros == ["humble", "jazzy", "kilted", "lyrical"], "\(entry.ir.rosTypeName)")
        }
        #expect(collected.collectedServices.map(\.typeName) == ["Probe"])
    }

    @Test("each distribution has the hashes of its own .srv, the service and its event included")
    func hashesAreProjectedPerDistribution() throws {
        let merged = try Self.probing()
        defer { merged.remove() }
        var own: [String: [String: String]] = [:]
        for distro in ["jazzy", "kilted", "lyrical"] {
            let single = try Self.probing([distro])
            defer { single.remove() }
            own[distro] = try ActionMergeTests.hashes(single.runs, distro)
            // The request, the response, the service and its event.
            #expect(own[distro]?.count == 4)
            #expect(try ActionMergeTests.hashes(merged.runs, distro) == own[distro], "\(distro)")
        }

        // Kilted changes the request and Lyrical the response; Kilted's constant is not hashed.
        func changes(_ suffix: String) -> [Bool] {
            let type = "fixture_msgs/srv/Probe\(suffix)"
            return [own["jazzy"]![type] != own["kilted"]![type], own["kilted"]![type] != own["lyrical"]![type]]
        }
        #expect(changes("_Request") == [true, false])
        #expect(changes("_Response") == [false, true])
        for suffix in ["", "_Event"] {
            #expect(changes(suffix) == [true, true], "\(suffix)")
        }
    }

    @Test("typeInfo(for:) of the umbrella and of each half returns each distribution's own hashes")
    func typeInfoHasEachDistributionsHashes() throws {
        let fixture = try Self.probing()
        defer { fixture.remove() }
        let files = try fixture.generate()
        var own: [String: ServiceHashes] = [:]
        for distro in ["jazzy", "kilted", "lyrical"] {
            own[distro] = try Self.ownHashes(distro)
        }
        // The umbrella built from the hashes of each distribution's own `.srv`: one step per
        // change, Rolling with Lyrical's.
        let umbrella = try #require(files["FixtureMsgs/ProbeSrv.swift"])
        let expected = SwiftEmitter.emitServiceUmbrella(
            package: "fixture_msgs", serviceTypeName: "Probe", umbrellaName: "ProbeSrv",
            requestStructName: "ProbeRequest", responseStructName: "ProbeResponse", hashesByDistro: own,
            sourceLabel: "fixture_msgs/srv/Probe.srv")
        #expect(umbrella == expected)
        for since in ["lyrical", "kilted"] {
            #expect(umbrella.contains("} else if distro >= .\(since) {"), "\(since)")
        }

        // Each half changes where its own `.srv` half does, newest first.
        let request = try #require(files["FixtureMsgs/ProbeRequest.swift"])
        #expect(MultiDistroFixture.hashes(in: request) == [own["kilted"]?.requestHash, own["jazzy"]?.requestHash])
        let response = try #require(files["FixtureMsgs/ProbeResponse.swift"])
        #expect(MultiDistroFixture.hashes(in: response) == [own["lyrical"]?.responseHash, own["jazzy"]?.responseHash])
    }

    @Test("a merged half guards and documents the fields only some distributions have")
    func mergedHalvesGuardTheirFields() throws {
        let fixture = try Self.probing()
        defer { fixture.remove() }
        let files = try fixture.generate()
        let request = try #require(files["FixtureMsgs/ProbeRequest.swift"])
        #expect(request.contains("        if encoder.isLegacySchema {\n            encoder.writeString(legacyMode)\n"))
        #expect(
            request.contains(
                "    /// Kilted and later only. Not encoded for an earlier distribution; decoded there as `0.5`.\n"
                    + "    public var tolerance: Double\n"))
        #expect(
            request.contains(
                "        if encoder.schemaDistro >= .kilted {\n            encoder.writeFloat64(tolerance)\n"))
        let response = try #require(files["FixtureMsgs/ProbeResponse.swift"])
        #expect(response.contains("    public static let OK: UInt8 = 0\n"))
        #expect(response.contains("    public static let BUSY: UInt8 = 2\n"))
        #expect(
            response.contains(
                "        if decoder.schemaDistro >= .lyrical {\n            self.success = try decoder.readBool()\n"
                    + "        } else {\n            self.success = false\n        }\n"
                    + "        self.status = try decoder.readUInt8()\n"))
    }

    @Test("the CDR tests compile the generated Probe service")
    func cdrFixtureIsGenerated() throws {
        let fixture = try Self.probing()
        defer { fixture.remove() }
        let files = try Pipeline.generateMulti(fixture.runs, moduleNames: ["fixture_msgs": "SwiftROS2CDRTests"])
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SwiftROS2CDRTests/Fixtures")
        for name in ["ProbeSrv", "ProbeRequest", "ProbeResponse"] {
            let file = try #require(files.first { $0.relativePath == "FixtureMsgs/\(name).swift" })
            let url = fixtures.appendingPathComponent("\(name).swift")
            #expect(try String(contentsOf: url, encoding: .utf8) == file.contents, "\(name)")
        }
    }

    @Test("a service that differs only in constants generates as its newest .srv, with one hash")
    func constantsOnlyDifference() throws {
        // As `nav2_msgs/srv/ManageLifecycleNodes`: Jazzy adds two commands to Humble's.
        let humble = "uint8 STARTUP=0\nuint8 command\n---\nbool success\n"
        let jazzy = "uint8 STARTUP=0\nuint8 CONFIGURE=5\nuint8 CLEANUP=6\nuint8 command\n---\nbool success\n"
        let fixture = try MultiDistroFixture([
            "humble": ["srv/M.srv": humble], "jazzy": ["srv/M.srv": jazzy], "lyrical": ["srv/M.srv": jazzy],
        ])
        defer { fixture.remove() }
        let single = try MultiDistroFixture(["jazzy": ["srv/M.srv": jazzy]])
        defer { single.remove() }
        let files = try fixture.generate()
        let own = try single.generate()
        for path in ["FixtureMsgs/MSrv.swift", "FixtureMsgs/MRequest.swift", "FixtureMsgs/MResponse.swift"] {
            #expect(files[path] != nil && files[path] == own[path], "\(path)")
        }
        #expect(files["FixtureMsgs/MSrv.swift"]?.contains("typeInfo(for distro:") == false)
    }

    @Test("a half field that skips a distribution is reported where it comes back")
    func halfFieldGapIsRejected() throws {
        let srv = ["int32 a\n---\nint32 b\nint32 extra\n", "int32 a\n---\nint32 b\n"]
        let error = try MergeErrorTests.error([
            "jazzy": ["srv/Gap.srv": srv[0]], "kilted": ["srv/Gap.srv": srv[1]], "lyrical": ["srv/Gap.srv": srv[0]],
        ])
        #expect(
            error?.hasSuffix(
                "/lyrical/fixture_msgs/srv/Gap.srv:4: service 'Gap' cannot be merged across distributions: "
                    + "response field 'extra' exists in [jazzy, lyrical] but not in [kilted] between them — a field "
                    + "must exist in one contiguous run of distributions") == true,
            "\(error ?? "no error")")
    }
}
