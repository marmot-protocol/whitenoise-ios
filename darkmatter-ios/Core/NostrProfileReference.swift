import Foundation

nonisolated enum NostrProfileReference {
    private static let bech32Charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
    /// O(1) reverse lookup for `bech32Charset`, built once. Decoding scans every
    /// character of every reference, so a linear `firstIndex(of:)` per character
    /// was O(n) per lookup (issue #33).
    private static let bech32CharsetIndex: [Character: UInt8] = {
        var index: [Character: UInt8] = [:]
        for (position, character) in bech32Charset.enumerated() {
            index[character] = UInt8(position)
        }
        return index
    }()
    private static let bech32Generators = [
        0x3b6a57b2,
        0x26508e6d,
        0x1ea119fa,
        0x3d4233dd,
        0x2a1462b3
    ]

    static func memberRef(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let reference = reference(fromDarkMatterURLString: trimmed) {
            return memberRef(fromReference: reference)
        }

        if trimmed.lowercased().hasPrefix("nostr:") {
            let rest = String(trimmed.dropFirst("nostr:".count))
            return memberRef(fromReference: rest)
        }

        return memberRef(fromReference: trimmed)
    }

    /// Hex pubkey from an `npub1…` or `nprofile1…` reference, checksum
    /// validated. nil for anything else (including bad checksums) so callers
    /// keep their bech32 fallback.
    static func pubkeyHex(fromBech32 reference: String) -> String? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("npub1") {
            guard let bytes = npubPubkeyBytes(trimmed) else { return nil }
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        if lower.hasPrefix("nprofile1") {
            return nprofilePubkeyHex(trimmed)
        }
        return nil
    }

    static func memberRef(fromReference reference: String) -> String? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        if lower.hasPrefix("nprofile1") {
            return nprofilePubkeyHex(trimmed)
        }
        if lower.hasPrefix("npub1") {
            guard npubPubkeyBytes(trimmed) != nil else { return nil }
            return trimmed
        }
        if Hex.is32Bytes(trimmed) {
            return lower
        }
        return nil
    }

    private static func reference(fromDarkMatterURLString raw: String) -> String? {
        guard let url = URL(string: raw),
              url.scheme?.lowercased() == DeepLink.scheme
        else { return nil }

        let parts = url.pathComponents.filter { $0 != "/" }
        switch url.host?.lowercased() {
        case "profile":
            return parts.first
        default:
            return url.host
        }
    }

    private static func npubPubkeyBytes(_ raw: String) -> [UInt8]? {
        guard let decoded = bech32Decode(raw),
              decoded.hrp == "npub",
              let bytes = convertBits(decoded.data, from: 5, to: 8, pad: false),
              bytes.count == 32
        else { return nil }
        return bytes
    }

    private static func nprofilePubkeyHex(_ raw: String) -> String? {
        guard let decoded = bech32Decode(raw),
              decoded.hrp == "nprofile",
              let bytes = convertBits(decoded.data, from: 5, to: 8, pad: false)
        else { return nil }

        var i = 0
        while i + 2 <= bytes.count {
            let type = bytes[i]
            let length = Int(bytes[i + 1])
            let start = i + 2
            let end = start + length
            guard end <= bytes.count else { return nil }

            if type == 0, length == 32 {
                return bytes[start..<end].map { String(format: "%02x", $0) }.joined()
            }
            i = end
        }
        return nil
    }

    private static func bech32Decode(_ raw: String) -> (hrp: String, data: [UInt8])? {
        let lower = raw.lowercased()
        guard raw == lower || raw == raw.uppercased(),
              let separator = lower.lastIndex(of: "1")
        else { return nil }

        let hrp = String(lower[..<separator])
        let dataPart = lower[lower.index(after: separator)...]
        guard !hrp.isEmpty,
              dataPart.count >= 6,
              // BIP-0173 requires HRP characters to be printable ASCII (33–126).
              // Enforcing this prevents a runtime trap in bech32VerifyChecksum
              // where a Unicode scalar > 0x1FFF overflows UInt8($0.value >> 5).
              hrp.unicodeScalars.allSatisfy({ (33...126).contains($0.value) })
        else { return nil }

        var values: [UInt8] = []
        values.reserveCapacity(dataPart.count)
        for char in dataPart {
            guard let value = bech32CharsetIndex[char] else { return nil }
            values.append(value)
        }

        guard bech32VerifyChecksum(hrp: hrp, values: values) else { return nil }
        return (hrp, Array(values.dropLast(6)))
    }

    private static func bech32VerifyChecksum(hrp: String, values: [UInt8]) -> Bool {
        var expanded: [UInt8] = hrp.unicodeScalars.map { UInt8($0.value >> 5) }
        expanded.append(0)
        expanded.append(contentsOf: hrp.unicodeScalars.map { UInt8($0.value & 31) })
        expanded.append(contentsOf: values)
        return bech32Polymod(expanded) == 1
    }

    private static func bech32Polymod(_ values: [UInt8]) -> Int {
        var checksum = 1
        for value in values {
            let top = checksum >> 25
            checksum = ((checksum & 0x1ffffff) << 5) ^ Int(value)
            for i in 0..<5 where ((top >> i) & 1) != 0 {
                checksum ^= bech32Generators[i]
            }
        }
        return checksum
    }

    private static func convertBits(_ data: [UInt8], from: Int, to: Int, pad: Bool) -> [UInt8]? {
        var acc = 0
        var bits = 0
        let maxv = (1 << to) - 1
        var result: [UInt8] = []

        for value in data {
            guard Int(value) >> from == 0 else { return nil }
            acc = (acc << from) | Int(value)
            bits += from
            while bits >= to {
                bits -= to
                result.append(UInt8((acc >> bits) & maxv))
            }
        }

        if pad {
            if bits > 0 {
                result.append(UInt8((acc << (to - bits)) & maxv))
            }
        } else {
            guard bits < from, ((acc << (to - bits)) & maxv) == 0 else { return nil }
        }
        return result
    }

}
