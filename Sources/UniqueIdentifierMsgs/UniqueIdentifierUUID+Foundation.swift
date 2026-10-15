// Bridges between the generated `UniqueIdentifierUUID` and `Foundation.UUID`.
//
// `uuid` is a public mutable `[UInt8]` without a length check at construction; the
// generated `init(uuid:)` defaults to 16 zero bytes, and `encode(to:)` checks the length.

import Foundation
import SwiftROS2Messages

extension UniqueIdentifierUUID {
    /// Build from a `Foundation.UUID`. The 16-byte tuple is unpacked into the
    /// `uuid: [UInt8]` storage in big-endian order, matching `UUID.uuid`.
    public init(foundationUUID: Foundation.UUID) {
        let t = foundationUUID.uuid
        self.init(uuid: [
            t.0, t.1, t.2, t.3, t.4, t.5, t.6, t.7,
            t.8, t.9, t.10, t.11, t.12, t.13, t.14, t.15,
        ])
    }

    /// Return the underlying 16 bytes as a `Foundation.UUID`. Reading this
    /// when `uuid.count < 16` is a programming error and traps via an
    /// out-of-bounds subscript.
    public var foundationUUID: Foundation.UUID {
        Foundation.UUID(
            uuid: (
                uuid[0], uuid[1], uuid[2], uuid[3],
                uuid[4], uuid[5], uuid[6], uuid[7],
                uuid[8], uuid[9], uuid[10], uuid[11],
                uuid[12], uuid[13], uuid[14], uuid[15]
            ))
    }
}
