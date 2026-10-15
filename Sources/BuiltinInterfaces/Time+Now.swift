// Hand-written additions to the generated `Time`.

import Foundation
import SwiftROS2Messages

/// `builtin_interfaces/msg/Time` under a name qualified by its package, for code that also
/// sees another `Time` type. It is the same type as ``Time``.
public typealias BuiltinInterfacesTime = Time

extension Time {
    /// The current wall-clock time.
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
