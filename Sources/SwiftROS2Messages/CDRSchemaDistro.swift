// CDRSchemaDistro.swift
// The distribution whose message schemas a CDR encoder or decoder uses.

import Foundation
import SwiftROS2CDR

/// The distribution a codec with `releaseIndex` and `isLegacySchema` was made for: the one at
/// that index, else Humble for a legacy codec and Jazzy otherwise (the 1.0 meaning of "modern").
private func schemaDistro(releaseIndex: Int?, isLegacySchema: Bool) -> ROS2Distro {
    if let releaseIndex, let distro = ROS2Distro(releaseIndex: releaseIndex) { return distro }
    return isLegacySchema ? .humble : .jazzy
}

extension CDREncoder {
    /// Creates an encoder that writes the message schemas of `distro`: generated types write a
    /// field only when `distro` has it.
    public convenience init(estimatedSize: Int = 256, distro: ROS2Distro) {
        self.init(
            estimatedSize: estimatedSize, schemaDistroName: distro.rawValue, releaseIndex: distro.releaseIndex,
            isLegacySchema: distro.isLegacySchema)
    }

    /// The distribution whose schema this encoder writes: the one it was created for, else
    /// Humble for a legacy encoder and Jazzy otherwise (the 1.0 meaning of "modern").
    public var schemaDistro: ROS2Distro {
        SwiftROS2Messages.schemaDistro(releaseIndex: schemaDistroReleaseIndex, isLegacySchema: isLegacySchema)
    }
}

extension CDRDecoder {
    /// Creates a decoder that reads the message schemas of `distro` (validates the encapsulation
    /// header): generated types read a field only when `distro` has it, and give it its default
    /// value otherwise.
    public convenience init(data: Data, distro: ROS2Distro) throws {
        try self.init(
            data: data, schemaDistroName: distro.rawValue, releaseIndex: distro.releaseIndex,
            isLegacySchema: distro.isLegacySchema)
    }

    /// The distribution whose schema this decoder reads: the one it was created for, else
    /// Humble for a legacy decoder and Jazzy otherwise (the 1.0 meaning of "modern").
    public var schemaDistro: ROS2Distro {
        SwiftROS2Messages.schemaDistro(releaseIndex: schemaDistroReleaseIndex, isLegacySchema: isLegacySchema)
    }
}
