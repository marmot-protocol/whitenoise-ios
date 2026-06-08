import Foundation

/// Validation and normalization for hex-encoded identifiers.
///
/// Nostr event ids, pubkeys, and Marmot group ids are 32-byte values encoded as
/// 64 lowercase hex characters. Relay- and peer-sourced strings must be checked
/// before they reach Marmot. This consolidates checks that were previously
/// duplicated across `DeepLink`, `NostrProfileReference`, and `MessageSemantics`
/// with subtly divergent semantics (issue #77).
///
/// Validation is strict ASCII (`0-9a-fA-F`). It deliberately does not use
/// `Character.isHexDigit`, which also matches non-ASCII forms such as fullwidth
/// or mathematical digits — peer-controlled input must not slip past as a valid
/// identifier.
enum Hex {
    /// True when `value` is a non-empty hex string of any length.
    static func isHex(_ value: String) -> Bool {
        let bytes = value.utf8
        return !bytes.isEmpty && bytes.allSatisfy(isHexByte)
    }

    /// True when `value` is exactly 64 hex characters — a 32-byte identifier.
    static func is32Bytes(_ value: String) -> Bool {
        let bytes = value.utf8
        return bytes.count == 64 && bytes.allSatisfy(isHexByte)
    }

    /// Trims surrounding whitespace, validates as a 64-character hex string, and
    /// lowercases it. Returns nil when `value` is missing or not a 32-byte hex
    /// identifier.
    static func normalized32Bytes(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              is32Bytes(trimmed)
        else { return nil }
        return trimmed.lowercased()
    }

    private static func isHexByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x30...0x39, 0x41...0x46, 0x61...0x66: // 0-9, A-F, a-f
            return true
        default:
            return false
        }
    }
}
