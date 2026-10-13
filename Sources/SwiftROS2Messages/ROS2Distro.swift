// ROS2Distro.swift
// ROS 2 distributions and the message-schema facts generated types depend on.

/// A ROS 2 distribution.
///
/// Generated message types read ``isLegacySchema`` to pick their wire shape and type hash.
/// New distributions are added in minor releases, so a `switch` over this enum needs a
/// `default` branch.
public enum ROS2Distro: String, CaseIterable, Sendable {
    case humble
    case jazzy
    case kilted
    case lyrical
    case rolling

    /// Display name, for example `"Jazzy"`.
    public var displayName: String { rawValue.capitalized }

    /// Whether this distribution carries RIHS01 type hashes (Iron and later).
    public var supportsTypeHash: Bool { !isLegacySchema }

    /// Whether this distribution uses the pre-Iron message schemas, for example
    /// `sensor_msgs/Range` without `variance`. Only Humble does.
    public var isLegacySchema: Bool { self == .humble }
}
