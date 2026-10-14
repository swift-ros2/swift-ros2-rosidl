/// Emits deterministic sample values for the CDR oracle.
///
/// Every field gets a fixed non-default value so a wrong offset, length prefix or alignment
/// shows up when rclpy round-trips the Swift bytes. Bounded strings and sequences stay
/// inside their bounds.
public enum OracleSampleEmitter {
    static let sampleString = "swift-ros2"

    /// A Swift expression for a sample value of `type`.
    public static func sampleExpression(_ type: FieldType, nestedNameOverrides: [String: String]) -> String {
        switch type {
        case .primitive(let p):
            switch p {
            case .bool: return "true"
            case .byte, .uint8: return "7"
            case .char, .int8: return "-5"
            case .int16: return "-300"
            case .uint16: return "300"
            case .int32: return "-70000"
            case .uint32: return "70000"
            case .int64: return "-5000000000"
            case .uint64: return "5000000000"
            case .float32: return "1.5"
            case .float64: return "-2.25"
            case .string, .wstring: return "\"\(sampleString)\""
            }
        case .boundedString(_, let upper):
            return "\"\(sampleString.prefix(upper))\""
        case .nested:
            return "\(SwiftEmitter.swiftType(type, nestedNameOverrides: nestedNameOverrides)).oracleSample()"
        case .array(let element, let length):
            let item = sampleExpression(element, nestedNameOverrides: nestedNameOverrides)
            return "Array(repeating: \(item), count: \(length))"
        case .sequence(let element, let upper):
            let count = min(2, upper ?? 2)
            let item = sampleExpression(element, nestedNameOverrides: nestedNameOverrides)
            return "[" + Array(repeating: item, count: count).joined(separator: ", ") + "]"
        }
    }

    /// `extension <structName> { static func oracleSample() -> <structName> }` for `ir`.
    public static func emitExtension(
        _ ir: MessageIR, structName: String, nestedNameOverrides: [String: String]
    ) -> String {
        var out = "extension \(structName) {\n"
        out += "    static func oracleSample() -> \(structName) {\n"
        if ir.fields.isEmpty {
            out += "        \(structName)()\n"
            out += "    }\n"
            out += "}\n"
            return out
        }
        out += "        var value = \(structName)()\n"
        for field in ir.fields {
            out += "        value.\(field.swiftName) = "
            out += "\(sampleExpression(field.type, nestedNameOverrides: nestedNameOverrides))\n"
        }
        out += "        return value\n"
        out += "    }\n"
        out += "}\n"
        return out
    }
}
