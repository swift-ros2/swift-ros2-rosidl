// Source-compat aliases for callers that pre-date the swift-ros2-gen migration.
// These keep the long names alive so that downstream consumers (and the action /
// service plumbing inside this repo) compile without a churn-only rename PR.
// New code should use the bare generated name (`Time`).

import Foundation
import SwiftROS2Messages

/// Source-compat alias for the legacy long name. New code should use `Time`.
public typealias BuiltinInterfacesTime = Time

extension Time {
    /// Wall-clock convenience used by integration tests / examples that pre-date
    /// the IDL-generated `Time` struct. The generator does not emit static
    /// helpers, so this stays as a hand-written extension.
    ///
    /// Saturates rather than traps after Jan 19 2038 03:14:07 UTC: `Int32(ti)`
    /// would overflow there, but `Int32(clamping:)` over an `Int64` intermediate
    /// pins to `Int32.max` instead — a more useful failure mode for callers.
    public static func now() -> Time {
        let ti = Date().timeIntervalSince1970
        let s = Int32(clamping: Int64(ti))
        let ns = UInt32(clamping: Int64((ti - Double(s)) * 1_000_000_000))
        return Time(sec: s, nanosec: ns)
    }
}
