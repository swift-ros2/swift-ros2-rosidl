# Changelog

## 1.0.0-rc.1

- Extracted from swift-ros2 2.3.2 (CDR, message protocols, runtime interfaces, swift-ros2-gen)
  with its history; the 2.3.2 state is commit `be8a4ae5f2e8b5499b6bb199d60684a29ae481f8` of this repository.
- `ROS2Distro` moved here from `SwiftROS2Wire`; wire-only members stay in swift-ros2.
- Removed the RCL marshalling and registry emitters, `Pipeline.generateRclMarshalling` and the `--emit-rcl-marshalling` CLI flags (RCL is a swift-ros2 runtime concern).
- Runtime interfaces are generated as one module per ROS package (`BuiltinInterfaces`, `UniqueIdentifierMsgs`, `ActionMsgs`, `RclInterfaces`).
- `swift-ros2-gen --dependency <pkg>=<path>@<distro>` takes packages that are referenced but not emitted.
- `swift-ros2-gen --module <pkg>=<Module>` overrides the module name of a package.
- Generated files import the modules of the packages they reference (derived imports).
- Distro-safe `typeInfo(for:)`: Humble gets the legacy schema and every later distribution the modern hash; a field that differs among modern distributions stops generation.
- ROS names equal to a Swift standard-library type get a `Msg` suffix, now including `DurationMsg`, `RangeMsg` and `ClockMsg`.
- The generator emits CDR oracle samples, and a Swift round-trip check verifies them. Each
  sample lists the distributions whose IDL has its type, and the corpus executable takes a
  distribution argument (`<corpus> <output-dir> <distro>`) that writes only that
  distribution's samples; `interface-oracles.yml` passes the row's distribution.
- Services and actions of a package read from several distributions carry the distributions
  that have them, as messages do: an action that only a later distribution has is generated
  (it was read from the first distribution only), an action whose shape differs between
  distributions is rejected like a service, and `--verify-hashes` checks service halves and
  action parts in each distribution that has them.
- Upstream IDL is pinned in `idl.lock` and fetched by `Scripts/fetch-idl.sh` into a gitignored cache (no submodules); generated Swift is committed.
- Reusable `interface-oracles.yml` workflow for hash and CDR oracles in interface repositories, with an `apt-packages` input.
- Empty action goals, results and feedback encode and decode rosidl's `structure_needs_at_least_one_member` byte, as empty messages and service halves already did; before, they wrote no body and rosidl subscribers rejected them.

### Known issues

- `wstring` (bounded or not) is encoded like `string` (UTF-8, NUL-terminated), which no RMW accepts: Fast-CDR-based RMWs (`rmw_fastrtps_cpp`, `rmw_zenoh_cpp`) and Jazzy's `rmw_cyclonedds_cpp` expect a UTF-16 code-unit count followed by one 4-byte unit per UTF-16 code unit, and Lyrical's `rmw_cyclonedds_cpp` expects a byte count followed by 2-byte units.
