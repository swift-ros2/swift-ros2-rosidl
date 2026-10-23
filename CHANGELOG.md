# Changelog

## Unreleased

### Added

- Message fields that differ among the distributions after Humble. Pass a package once per
  distribution and the generator merges the IDL into one type: a field that only some
  distributions have is written and read only for them (`encoder.schemaDistro >= .lyrical`),
  is decoded as its IDL default elsewhere, and says so in its doc comment. A message, service
  or action whose hash differs among distributions, including one that only reaches such a
  type (even one read for more distributions than the type itself), gets `typeInfo(for:)` with
  one hash per change; `typeInfo` stays the Jazzy one. A
  distribution with no IDL passed (Rolling) takes the newest passed distribution that is not
  newer (`IRBuilder.schemaDistro(for:read:)`). Types that differ only on Humble generate as
  before.
- `ROS2Distro` is `Comparable` in release order, Rolling greatest.
- `CDREncoder(distro:)`, `CDRDecoder(data:distro:)` and `schemaDistro` on both, and
  `schemaDistroName` in `SwiftROS2CDR`. The existing initializers keep the 1.0 behaviour
  (Humble when legacy, otherwise Jazzy).
- `typeInfo(for:)` requirements on `ROS2MessageType`, `ROS2ServiceType` and `ROS2Action`, with
  default implementations that return `typeInfo` without its hashes on Humble, and
  `withoutTypeHashes` on the three type info structs. swift-ros2 needs them to send the
  layout and hash of the distribution it runs against.
- `SwiftEmitter.emitServiceUmbrella(…, hashesByDistro:, …)` and `ServiceHashes`.
- The generated oracle corpus encodes and decodes the samples of `OracleSamples.samples(for:)`
  with that distribution's message schemas (`OracleSamples.all` keeps the default ones), and
  `RosidlOracleCorpus` round-trips both sets.

### Changed

- Fields that two distributions have in a different order are rejected (`IRBuildError`); the
  merged type used the first distribution's order for all of them.
- `GeneratorError.modernDistroDivergence` now reports a field missing from a distribution
  between two that have it; any other difference among modern distributions is supported.
- `RIHS01.hash(_:for:registry:)` projects a merged type onto the distribution it was read for
  that gives its shape (see above) when asked for a distribution it was not read for.
- `swift-ros2-gen --verify-hashes --distros <d>` reads every `--input` distribution and checks
  every type on every selected distribution (default: every distribution of the inputs but
  Humble) with the hash its generated `typeInfo(for:)` returns there, including distributions
  its package was not read for (Rolling); a type missing from a distribution its package was
  read for is skipped there. The `interface-oracles.yml` hash oracle passes every
  generated distribution (`Scripts/generator-args.sh` without an argument) with
  `--distros <row>`, so it verifies the hashes the generated code carries rather than one
  distribution's IDL alone.

### Fixed

- A message with no fields in some distributions writes and reads rosidl's
  `structure_needs_at_least_one_member` byte in exactly those distributions (Humble splits
  included), matching its hash; the codec wrote nothing there.

- A field a later distribution adds in the middle of a message is placed where that
  distribution has it, not at the end.
- `IRBuilder.populateActionHashes(_:distro:extraRegistry:)` projects the types an action
  references onto `distro` instead of hashing every field any distribution has.

## 1.0.1

Patch release for the reusable oracle workflow; the package code is unchanged since 1.0.0.

### Fixed

- The `interface-oracles.yml` reusable workflow upgrades the oracle image's packages after
  installing `apt-packages`, so freshly installed packages no longer fail against an older
  published `osrf/ros` image (for example a missing `ServiceEventInfo` symbol on Lyrical).
  Callers without `apt-packages` get the same image as before.

## 1.0.0

First stable release; the public API is now covered by semantic versioning. The code is
unchanged since 1.0.0-rc.3, which was checked against live ROS 2 Humble, Jazzy, Kilted and
Lyrical hosts over Zenoh and DDS through swift-ros2 3.0.0-rc.3.

- The README now says `--module` only changes the generated `import`s (files still land in
  `<PascalCasePackage>/`), quotes the full unresolved-nested-type error, and excludes `srv/`
  and `action/` directories when using the build plugin (#34).

## 1.0.0-rc.3

Last release candidate before the 1.0.0 API freeze.

### Removed (breaking)

- Dead public API: the `ROS2Publishable` / `ROS2Subscribable` aliases, the three-hash
  `ROS2ActionTypeInfo` initializer, `CDRDecodingError.invalidArraySize`,
  `Pipeline.generate(for:)` (use `generateMulti`) with `RIHS01.hash(_:)`,
  `Pipeline.buildMessageRegistry`, `FieldType.rosTypeName`, and the swift-ros2-gen options
  `--extra-import` and `--exclude-types` (#21).
- `CDRSerializationError` keeps only the cases generated code throws (#23).

### Changed

- Malformed IDL is reported as an error with the file and line instead of stopping
  swift-ros2-gen on a precondition failure: `IRBuilder.build(jazzy:)` throws, and every pipeline
  error is printed as `error: ...` with exit status 1 (#22).
- Generated `encode(to:)` throws `CDRSerializationError` for fixed arrays and bounded sequences
  of the wrong length instead of trapping (#23).
- Bounded strings (`string<=N`, and arrays and sequences of them) are length-checked: encoding
  throws `CDRSerializationError.stringTooLong`, decoding throws
  `CDRDecodingError.boundedStringTooLong`, counting UTF-8 bytes without the terminating NUL as
  rosidl does; new `CDRDecoder.readString(maxLength:)` (#30).
- `wstring` fields (bounded or not, alone or in arrays and sequences) are rejected with
  `wstring is not supported yet` until the generator implements the RMW encodings; `wstring`
  constants are still accepted (#31).
- Generated service umbrella files no longer import `SwiftROS2CDR`, and every generated file's
  `// Source:` line is `<pkg>/<kind>/<Type>.<kind>` (#24, #25).

### Internal

- One IDL directory walk for messages, services and actions; development-phase comments
  replaced (#24, #26).
- Drift guards for the build plugin's naming table and the distro list; DocC builds every
  library target; CI caches the Swift toolchain and SDK downloads and retries them
  (#27, #28, #29).

## 1.0.0-rc.2

- `ROS2ServiceTypeInfo.serviceTypeHash` carries the service-level type hash, and
  `ROS2ActionTypeInfo.sendGoalServiceTypeHash` / `getResultServiceTypeHash` carry the hashes
  of an action's `SendGoal` and `GetResult` services. rmw_zenoh_cpp keys services and action
  services by these hashes, not by the request hash. The new initializer parameters default
  to `nil`, so existing call sites compile unchanged.
- swift-ros2-gen emits these hashes for every `.srv` and `.action` (nil for Humble). It builds
  the `<Srv>_Event` and `ServiceEventInfo` types that the service description needs, so no
  `service_msgs` dependency is required, and `--verify-hashes` also checks service-level,
  `_Event` and action-level hashes. `ActionMsgs` and `RclInterfaces` are regenerated.
- swift-ros2-gen reports an unresolved element type of an array or sequence field
  (`Foo[]`, `Foo[3]`, `Foo[<=3]`) as `GeneratorError.unresolvedNestedType` instead of
  stopping on a precondition failure.
- The README walks through generating a message package, packaging it as a Swift module and
  publishing it with swift-ros2, and documents `SwiftROS2GenPlugin` and `--verify-hashes`.

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
