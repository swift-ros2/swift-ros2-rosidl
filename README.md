# swift-ros2-rosidl

The ROS 2 interface layer for Swift: the CDR codec, the `ROS2Message` / `ROS2ServiceType` /
`ROS2Action` protocols, `ROS2Distro`, the runtime interface packages and the `swift-ros2-gen`
code generator. Pure Swift, no binary targets.

Part of the [swift-ros2](https://github.com/swift-ros2) org. Standard messages live in
[swift-ros2-common-interfaces](https://github.com/swift-ros2/swift-ros2-common-interfaces);
the transports and node API in [swift-ros2](https://github.com/swift-ros2/swift-ros2).

## Modules

| Module | Contents |
| --- | --- |
| `SwiftROS2CDR` | XCDR v1 encoder and decoder |
| `SwiftROS2Messages` | `ROS2Message`, `ROS2ServiceType`, `ROS2Action`, type-info structs, `ROS2Distro` |
| `BuiltinInterfaces` | `Time`, `DurationMsg` |
| `UniqueIdentifierMsgs` | `UniqueIdentifierUUID` |
| `ActionMsgs` | `GoalInfo`, `GoalStatus`, `GoalStatusArray`, `CancelGoalSrv` |
| `RclInterfaces` | parameter messages and services |
| `SwiftROS2Gen`, `swift-ros2-gen`, `SwiftROS2GenPlugin` | the code generator |

## Generating a type package

`swift-ros2-gen` turns the `.msg`, `.srv` and `.action` files of ROS packages into Swift
modules, one module per ROS package, named by PascalCasing the package
(`audio_common_msgs` → `AudioCommonMsgs`). The steps below generate `audio_common_msgs` (from
[ros-drivers/audio_common](https://github.com/ros-drivers/audio_common)) into a Swift package
called `AudioCommonMsgs` and publish its `AudioDataStamped` with swift-ros2.

### 1. Get the generator

`swift-ros2-gen` is an executable product of this package. Run it from a clone. Use the tag
that the generated module will depend on, because generated code targets the protocols of that
release:

```bash
git clone --branch 1.0.0 https://github.com/swift-ros2/swift-ros2-rosidl.git
cd swift-ros2-rosidl
swift run swift-ros2-gen --help
```

The generator resolves relative paths against the current directory, which is the clone. So
`--output` must point at the `Sources` directory of **your** package, for example
`../AudioCommonMsgs/Sources`, not at the clone.

When the generated module exists, you can regenerate it from your own package too:
`swift run swift-ros2-gen …` in a package that depends on swift-ros2-rosidl runs the
dependency's executable. This does not work for the first generation. Until the files exist,
the module's target has no sources, and SwiftPM rejects the package ("target … is empty").

### 2. Get the IDL

The generator reads a ROS package directory with `msg/`, `srv/` and `action/` subdirectories.
Each directory is passed as `<package>=<directory>@<distribution>`. Take the IDL of your
package and of every package it references from the upstream repository at the branch of the
distribution you target:

| Packages | Repository |
| --- | --- |
| `std_msgs`, `geometry_msgs`, `sensor_msgs`, `nav_msgs`, `std_srvs`, … | [ros2/common_interfaces](https://github.com/ros2/common_interfaces) |
| `builtin_interfaces`, `action_msgs`, `rcl_interfaces`, … | [ros2/rcl_interfaces](https://github.com/ros2/rcl_interfaces) |
| `unique_identifier_msgs` | [ros2/unique_identifier_msgs](https://github.com/ros2/unique_identifier_msgs) |

A ROS 2 installation works too: `/opt/ros/<distro>/share/<package>` holds `msg/*.msg`,
`srv/*.srv` and `action/*.action`.

```bash
cd ..
git clone --depth 1 --branch ros2 https://github.com/ros-drivers/audio_common.git
git clone --depth 1 --branch jazzy https://github.com/ros2/common_interfaces.git
git clone --depth 1 --branch jazzy https://github.com/ros2/rcl_interfaces.git
```

### 3. Pass every referenced package, transitively

Pass the packages you emit with `--input` and every package they reference with
`--dependency`. A dependency's types are parsed, resolved and hashed, but not emitted, because
they live in another Swift module (swift-ros2-common-interfaces for `std_msgs` and the other
standard packages, or this package for `builtin_interfaces`). The RIHS01 type hash covers every
nested type down to the primitives, so the generator needs all of them. For example,
`AudioDataStamped` has a `std_msgs/Header`, and `Header` has a `builtin_interfaces/Time`. A
message with a `std_msgs/Header` and a `sensor_msgs/PointField[]` needs `std_msgs`,
`builtin_interfaces` and `sensor_msgs`. A missing package stops generation with
`unresolved nested type '<pkg>/<Type>' — pass --input or --dependency for '<pkg>' on the same CLI invocation`.

The generator parses each dependency as a whole package (`--types` filters only `--input`), so
the references inside a dependency must resolve too. Passing all of `sensor_msgs` also needs
`geometry_msgs`. You can pass it, or point `--dependency` at a directory that holds only the
files you need, such as `deps/sensor_msgs/msg/PointField.msg`.

```bash
cd swift-ros2-rosidl
mkdir -p ../AudioCommonMsgs/Sources
swift run swift-ros2-gen \
  --input audio_common_msgs=../audio_common/audio_common_msgs@jazzy \
  --dependency std_msgs=../common_interfaces/std_msgs@jazzy \
  --dependency builtin_interfaces=../rcl_interfaces/builtin_interfaces@jazzy \
  --output ../AudioCommonMsgs/Sources
```

`--dry-run` prints the files instead of writing them. `--types A,B` emits only some types of
the `--input` packages. `--module <pkg>=<Module>` changes only the module name that generated
files `import` for a package, for example `--module audio_common_msgs=Audio` makes the files
that reference `audio_common_msgs` write `import Audio`. It does not move the emitted files: they
still go to `<PascalCasePackage>/`, so name your Swift target to match the module you pass.

### Distributions

The `@<distribution>` label says which distribution the IDL comes from. Generated types carry
one RIHS01 hash for every distribution from Jazzy on. Humble has no type hashes; swift-ros2
drops the hash there. Generated types also carry one field layout for Jazzy and later, plus a
Humble layout when you pass Humble IDL and its fields differ.

- **One snapshot for all distributions.** When you pass one snapshot, for example everything
  `@jazzy`, the hash is the hash of that snapshot's IDL, your package and every dependency.
  It is correct on every distribution whose IDL for those packages is the same. If a referenced
  package changed in a later distribution, hosts on that distribution compute a different hash,
  and rmw_zenoh_cpp does not match the topic. Generate from the IDL of the distributions you
  deploy against, and check with `--verify-hashes` on each one.
- **Humble differences.** If a message of yours has fields that differ between Humble and later
  distributions, pass the package once per distribution (`…@humble` and `…@jazzy`). The
  generator merges them into one type that picks its layout at run time. Differences among
  Jazzy and later distributions are rejected, because generated types support only one modern
  layout.

ROS names that equal a Swift standard-library type get a `Msg` suffix (`StringMsg`,
`DurationMsg`, `RangeMsg`).

### Output layout

`--output <dir>` writes `<dir>/<PascalCasePackage>/<Type>.swift`, for example
`<dir>/AudioCommonMsgs/AudioData.swift` for `audio_common_msgs`. `--module` does not change the
directory. The files are:

- a message: `<Type>.swift`;
- a service: `<Srv>Srv.swift` (the `ROS2ServiceType`), `<Srv>Request.swift` and
  `<Srv>Response.swift`;
- an action: `<Action>Action.swift`.

```
AudioCommonMsgs/
├── Package.swift
└── Sources/
    └── AudioCommonMsgs/
        ├── AudioData.swift
        ├── AudioDataStamped.swift
        └── AudioInfo.swift
```

There is no `Generated/` subdirectory, so `--output Sources` fills the target named after the
package (`Sources/AudioCommonMsgs/`). The generator overwrites files and never deletes them, so remove the files of deleted
types yourself. (This repository's `Scripts/regenerate.sh` copies its own output into
`Sources/<Module>/Generated/`. That is a convention of this repository, not generator output.)

### 4. Package the module

A generated file imports `SwiftROS2CDR`, `SwiftROS2Messages` and the module of every package it
references, so the module's target depends on those products. A program that publishes or
subscribes depends on `SwiftROS2` from swift-ros2:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AudioCommonMsgs",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "AudioCommonMsgs", targets: ["AudioCommonMsgs"])
    ],
    dependencies: [
        .package(url: "https://github.com/swift-ros2/swift-ros2-rosidl.git", from: "1.0.0"),
        .package(url: "https://github.com/swift-ros2/swift-ros2-common-interfaces.git", from: "1.0.0"),
        .package(url: "https://github.com/swift-ros2/swift-ros2.git", from: "3.0.0"),
    ],
    targets: [
        // The generated types: every module a generated file imports is a dependency.
        .target(
            name: "AudioCommonMsgs",
            dependencies: [
                .product(name: "SwiftROS2CDR", package: "swift-ros2-rosidl"),
                .product(name: "SwiftROS2Messages", package: "swift-ros2-rosidl"),
                .product(name: "StdMsgs", package: "swift-ros2-common-interfaces"),
            ]),
        // A program that publishes them.
        .executableTarget(
            name: "audio-talker",
            dependencies: [
                "AudioCommonMsgs",
                .product(name: "SwiftROS2", package: "swift-ros2"),
                .product(name: "StdMsgs", package: "swift-ros2-common-interfaces"),
            ]),
    ]
)
```

`Sources/audio-talker/main.swift`:

```swift
import AudioCommonMsgs
import StdMsgs
import SwiftROS2

let context = try await ROS2Context(transport: .ddsMulticast(domainId: 0), distro: .jazzy)
let node = try await context.createNode(name: "audio_talker", namespace: "/")
let publisher = try await node.createPublisher(AudioDataStamped.self, topic: "audio")
for i in 0..<30 {
    try publisher.publish(
        AudioDataStamped(header: Header(frameId: "mic"), audio: AudioData(data: [1, 2, 3, UInt8(i)])))
    try await Task.sleep(nanoseconds: 500_000_000)
}
```

On a host with `ros-jazzy-audio-common-msgs`,
`ros2 topic echo /audio audio_common_msgs/msg/AudioDataStamped` prints the messages.

### Checking hashes: `--verify-hashes`

`--verify-hashes <image>` generates nothing. It compares the RIHS01 hash of every type of the
`--input` packages with the hash rosidl wrote into
`/opt/ros/<distro>/share/<pkg>/<msg|srv|action>/<Type>.json`, which it reads with
`docker run --rm <image> cat …`. For a service or an action, it also checks every synthesized
type (`_Request`, `_Response`, `_SendGoal_Request`, …). Dependencies are not checked. The
command exits non-zero on a mismatch or a type the image lacks.

It needs Docker and an image in which the packages are installed. `osrf/ros:<distro>-desktop`
has the desktop packages; for others, add them:

```bash
printf 'FROM osrf/ros:jazzy-desktop\nRUN apt-get update && apt-get install -y --no-install-recommends ros-jazzy-audio-common-msgs\n' \
  | docker build -t audio-oracle:jazzy -
swift run swift-ros2-gen \
  --input audio_common_msgs=../audio_common/audio_common_msgs@jazzy \
  --dependency std_msgs=../common_interfaces/std_msgs@jazzy \
  --dependency builtin_interfaces=../rcl_interfaces/builtin_interfaces@jazzy \
  --verify-hashes audio-oracle:jazzy
# hash-oracle: 3/3 types match
```

`--distros` selects the distributions to check. The default is every distribution of the
inputs except Humble, and each one must be the distribution of the image. `--diagnose` writes
the oracle JSON of a mismatch under `/tmp/swift-ros2-gen-diagnose/`.

### The build plugin

`SwiftROS2GenPlugin` runs `swift-ros2-gen` during the build, so the generated files are not
committed. It covers only self-contained message packages:

- It reads only `msg/*.msg` directly inside the target's directory. It ignores `.srv` and
  `.action` files with a warning. If `srv/` or `action/` directories sit inside the target,
  list them in `exclude:` too, or SwiftPM warns that it found unhandled files.
- The target's name is the ROS package name, so name the target after the package
  (`my_msgs`). The type names (`my_msgs/msg/Point2`) and the hashes use it.
- It passes no `--dependency`. A field may use only primitives and other messages of the same
  `msg/` directory; `builtin_interfaces/Time` or `std_msgs/Header` stops the build with
  `unresolved nested type`.
- It reads the IDL as Jazzy (`@jazzy`) and has no per-distribution input, so it cannot merge
  Humble differences.
- It passes no `--module`.
- The target still needs one Swift file of its own. SwiftPM drops a target without sources
  before the plugin runs.

```swift
.target(
    name: "my_msgs",
    dependencies: [
        .product(name: "SwiftROS2CDR", package: "swift-ros2-rosidl"),
        .product(name: "SwiftROS2Messages", package: "swift-ros2-rosidl"),
    ],
    // The plugin reads msg/ itself; srv/ and action/ are ignored, and excluding them silences
    // SwiftPM's "unhandled files" warning. Drop the entries for directories you do not have.
    exclude: ["msg", "srv", "action"],
    plugins: [.plugin(name: "SwiftROS2GenPlugin", package: "swift-ros2-rosidl")]),
```

For anything else (services, actions, references to other packages, Humble variants), run the
CLI and commit its output.

## Upstream IDL and regeneration

This repository has no submodules and vendors no IDL, so packages that depend on it never
download any. `idl.lock` pins one upstream commit per repository and distribution
(`<name> <url> <distribution> <commit>`), and `Scripts/fetch-idl.sh` downloads exactly those
commits into the gitignored `.idl/` cache, verifying each SHA. `Scripts/regenerate.sh` runs it
first and rewrites `Sources/<Module>/Generated/`, which is committed; CI fails when the
committed sources differ from what `idl.lock` produces.

To move to newer upstream IDL, change the commit on the line
(`git ls-remote <url> refs/heads/<distribution>`), run `Scripts/regenerate.sh` and commit
`idl.lock` together with the regenerated sources.

## Interface repositories and the oracles

Other interface repositories (swift-ros2-common-interfaces, later swift-ros2-extra-interfaces)
use the same layout: an `idl.lock`, a copy of `Scripts/fetch-idl.sh`, a
`Scripts/generator-args.sh` that prints every distribution's arguments, or with one
distribution argument only that distribution labelled with it (`rolling` reads the Lyrical
IDL), and an internal corpus executable built from `--emit-oracle-samples` output. They call
the reusable workflow at the rosidl version their `Package.resolved` pins:

```yaml
jobs:
  interfaces:
    uses: swift-ros2/swift-ros2-rosidl/.github/workflows/interface-oracles.yml@1.0.0
    with:
      corpus-product: MyInterfacesOracleCorpus
      apt-packages: ros-${distro}-moveit-msgs   # only when the desktop image lacks a package
```

The workflow checks every RIHS01 hash against `osrf/ros:<distro>-desktop` and round-trips
every generated sample through Swift, and the samples of the row's distribution through
rclpy. Jazzy and Lyrical run on every event; Kilted and Rolling run on the caller's weekly
`schedule` and are non-blocking.

The corpus executable is a copy of `Sources/RosidlOracleCorpus/main.swift` compiled with the
generated `OracleSamples*.swift` files. The workflow runs it as
`swift run <corpus-product> <output-dir> <distro>`:

- It decodes and re-encodes every generated sample in Swift and exits 1 when any round-trip
  changes the bytes.
- It writes `<output-dir>/<pkg>/<msg|srv|action>/<Name>.cdr` for the samples of the types
  `<distro>` has: each sample lists the distributions whose IDL has its type, so a type that
  only some distributions have (geometry_msgs `Pose2D` is not in Lyrical) is left out of the
  others. `rolling` gets the Lyrical set unless Rolling IDL was generated. Without `<distro>`
  it writes every sample; `<output-dir>` defaults to `oracle-corpus`.
- It exits 2 when no IDL was generated for `<distro>`.

`Scripts/cdr-oracle.py` stays strict: a sample whose type the oracle image lacks fails.
