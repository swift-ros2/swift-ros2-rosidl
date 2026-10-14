# Changelog

## Unreleased

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
- Removed the RCL emitters from the generator.
- The generator emits CDR oracle samples, and a Swift round-trip check verifies them.
- Upstream IDL is pinned in `idl.lock` and fetched by `Scripts/fetch-idl.sh` into a gitignored cache (no submodules); generated Swift is committed.
- Reusable `interface-oracles.yml` workflow for hash and CDR oracles in interface repositories, with an `apt-packages` input.
