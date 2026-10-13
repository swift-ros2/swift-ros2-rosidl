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

Each ROS package becomes one Swift module named by PascalCasing the package
(`geometry_msgs` → `GeometryMsgs`). Pass the packages you emit with `--input` and the
packages they reference with `--dependency`; the generated files import the referenced
modules.

```bash
swift run swift-ros2-gen \
  --input my_msgs=path/to/my_msgs@jazzy \
  --dependency std_msgs=path/to/common_interfaces/std_msgs@jazzy \
  --dependency builtin_interfaces=path/to/rcl_interfaces/builtin_interfaces@jazzy \
  --output Sources
```

`--module <pkg>=<Module>` puts a package in a different module. Give each package once per
distribution (`@humble`, `@jazzy`, `@kilted`, `@lyrical`) to merge them into one type; fields
may differ between Humble and later distributions, not among the later ones.

ROS names equal to a Swift standard-library type get a `Msg` suffix (`StringMsg`,
`DurationMsg`, `RangeMsg`).

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
every generated sample through Swift and rclpy. Jazzy and Lyrical run on every event; Kilted
and Rolling run on the caller's weekly `schedule` and are non-blocking.
