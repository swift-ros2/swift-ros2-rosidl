// ROS2Distro.swift
// ROS 2 distributions and the message-schema facts generated types depend on.

/// A ROS 2 distribution.
///
/// Generated message types read ``isLegacySchema``, or compare a codec's `schemaDistro` with a
/// distribution (`encoder.schemaDistro >= .lyrical`), to pick their wire shape and type hash.
/// New distributions are added in minor releases, so a `switch` over this enum needs a
/// `default` branch; prefer comparisons, which keep their meaning when a distribution is added.
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

    /// Position in release order. Rolling is always last; a distribution added later goes
    /// before it.
    private var releaseIndex: Int {
        switch self {
        case .humble: return 0
        case .jazzy: return 1
        case .kilted: return 2
        case .lyrical: return 3
        case .rolling: return 4
        }
    }
}

extension ROS2Distro: Comparable {
    /// Release order, which is ``allCases`` order: an older distribution is less than a newer
    /// one, and Rolling is always the greatest.
    public static func < (lhs: ROS2Distro, rhs: ROS2Distro) -> Bool {
        lhs.releaseIndex < rhs.releaseIndex
    }
}
