import Foundation

nonisolated enum NostrProfileReference {
    private static let bech32Charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
    private static let maxBech32ReferenceUTF8Bytes = 4096
    private static let maxRelayHints = 8
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
        guard let reference = referenceForResolution(from: raw) else { return nil }
        return memberRef(fromReference: reference)
    }

    /// Validates a pasted/scanned/deep-linked profile reference while
    /// preserving the reference form for Marmot resolution. `nprofile` relay
    /// hints are peer-controlled network destinations, so the value is rebuilt
    /// with only bounded public WSS hints before it reaches Rust.
    static func referenceForResolution(from raw: String) -> String? {
        guard isWithinReferenceLimit(raw) else { return nil }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if looksLikeProfileReference(trimmed) {
            return referenceForResolution(fromReference: trimmed)
        }

        if hasCaseInsensitivePrefix(trimmed, "nostr:") {
            let rest = String(trimmed.dropFirst("nostr:".count))
            return referenceForResolution(fromReference: rest)
        }

        if let reference = reference(fromDeepLinkURLString: trimmed) {
            return referenceForResolution(fromReference: reference)
        }

        return referenceForResolution(fromReference: trimmed)
    }

    static func referenceForResolution(fromReference reference: String) -> String? {
        guard isWithinReferenceLimit(reference) else { return nil }
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)

        if hasCaseInsensitivePrefix(trimmed, "nprofile1") {
            return sanitizedNprofile(trimmed)
        }
        if hasCaseInsensitivePrefix(trimmed, "npub1") {
            guard npubPubkeyBytes(trimmed) != nil else { return nil }
            return trimmed.lowercased()
        }
        if Hex.is32Bytes(trimmed) {
            return trimmed.lowercased()
        }
        return nil
    }

    /// Hex pubkey from an `npub1…` or `nprofile1…` reference, checksum
    /// validated. nil for anything else (including bad checksums) so callers
    /// keep their bech32 fallback.
    static func pubkeyHex(fromBech32 reference: String) -> String? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if hasCaseInsensitivePrefix(trimmed, "npub1") {
            guard let bytes = npubPubkeyBytes(trimmed) else { return nil }
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        if hasCaseInsensitivePrefix(trimmed, "nprofile1") {
            return nprofilePubkeyHex(trimmed)
        }
        return nil
    }

    static func npub(fromAccountIdHex accountIdHex: String) -> String? {
        guard let bytes = pubkeyBytes(fromHex: accountIdHex),
              let data = convertBits(bytes, from: 8, to: 5, pad: true)
        else { return nil }
        return bech32Encode(hrp: "npub", data: data)
    }

    /// Validates and canonicalizes a NIP-19 private key before it crosses the
    /// Swift/Rust boundary. Shape checks alone accept mistyped checksums.
    static func normalizedNsec(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let decoded = bech32Decode(trimmed),
              decoded.hrp == "nsec",
              let bytes = convertBits(decoded.data, from: 5, to: 8, pad: false),
              bytes.count == 32
        else { return nil }
        return trimmed.lowercased()
    }

    /// NIP-19 nprofile encoder used when a caller needs to preserve relay hints.
    /// Apply the same destination policy as the decoder so values are safe even
    /// before an optional later resolution pass.
    static func nprofile(fromAccountIdHex accountIdHex: String, relayHints: [String]) -> String? {
        guard let pubkey = pubkeyBytes(fromHex: accountIdHex) else { return nil }
        var tlv: [UInt8] = [0, UInt8(pubkey.count)] + pubkey
        var seenRelays = Set<String>()
        var acceptedRelayCount = 0
        for rawRelay in relayHints {
            guard acceptedRelayCount < maxRelayHints else { break }
            guard rawRelay.utf8.count <= Int(UInt8.max),
                  let relay = RelayURL.normalized(rawRelay),
                  relay.utf8.count <= Int(UInt8.max),
                  seenRelays.insert(relay).inserted
            else { continue }
            let bytes = Array(relay.utf8)
            tlv.append(1)
            tlv.append(UInt8(bytes.count))
            tlv.append(contentsOf: bytes)
            acceptedRelayCount += 1
        }
        guard let data = convertBits(tlv, from: 8, to: 5, pad: true) else { return nil }
        return bech32Encode(hrp: "nprofile", data: data)
    }

    static func memberRef(fromReference reference: String) -> String? {
        guard isWithinReferenceLimit(reference) else { return nil }
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)

        if hasCaseInsensitivePrefix(trimmed, "nprofile1") {
            return nprofilePubkeyHex(trimmed)
        }
        if hasCaseInsensitivePrefix(trimmed, "npub1") {
            guard npubPubkeyBytes(trimmed) != nil else { return nil }
            // Normalize to lowercase to match the hex and nprofile branches.
            // bech32 is canonically lowercase (BIP-173) and the checksum is
            // already validated above, so a scanned/pasted `NPUB1…` must not
            // flow downstream un-normalized (would break ref-text dedup and
            // may be mis-keyed/rejected by Marmot).
            return trimmed.lowercased()
        }
        if Hex.is32Bytes(trimmed) {
            return trimmed.lowercased()
        }
        return nil
    }

    private static func reference(fromDeepLinkURLString raw: String) -> String? {
        guard let url = URL(string: raw),
              DeepLink.isKnownInteropScheme(url.scheme)
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
        parseNprofile(raw)?.pubkey.map { String(format: "%02x", $0) }.joined()
    }

    private static func sanitizedNprofile(_ raw: String) -> String? {
        guard let parsed = parseNprofile(raw) else { return nil }
        var tlv: [UInt8] = [0, UInt8(parsed.pubkey.count)] + parsed.pubkey
        for relay in parsed.relayHints {
            let bytes = Array(relay.utf8)
            guard bytes.count <= Int(UInt8.max) else { continue }
            tlv.append(1)
            tlv.append(UInt8(bytes.count))
            tlv.append(contentsOf: bytes)
        }
        guard let data = convertBits(tlv, from: 8, to: 5, pad: true) else { return nil }
        return bech32Encode(hrp: "nprofile", data: data)
    }

    private static func parseNprofile(_ raw: String) -> (pubkey: [UInt8], relayHints: [String])? {
        guard let decoded = bech32Decode(raw),
              decoded.hrp == "nprofile",
              let bytes = convertBits(decoded.data, from: 5, to: 8, pad: false)
        else { return nil }

        var pubkey: [UInt8]?
        var relayHints: [String] = []
        var seenRelays = Set<String>()
        var i = 0
        while i + 2 <= bytes.count {
            let type = bytes[i]
            let length = Int(bytes[i + 1])
            let start = i + 2
            let end = start + length
            guard end <= bytes.count else { return nil }

            switch type {
            case 0:
                guard length == 32, pubkey == nil else { return nil }
                pubkey = Array(bytes[start..<end])
            case 1 where relayHints.count < maxRelayHints:
                if let rawRelay = String(bytes: bytes[start..<end], encoding: .utf8),
                   let relay = RelayURL.normalized(rawRelay),
                   seenRelays.insert(relay).inserted {
                    relayHints.append(relay)
                }
            default:
                break
            }
            i = end
        }
        guard i == bytes.count, let pubkey else { return nil }
        return (pubkey, relayHints)
    }

    private static func pubkeyBytes(fromHex raw: String) -> [UInt8]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Hex.is32Bytes(trimmed) else { return nil }

        let bytes = Array(trimmed.utf8)
        var result: [UInt8] = []
        result.reserveCapacity(32)
        var index = 0
        while index < bytes.count {
            guard let high = hexNibble(bytes[index]),
                  let low = hexNibble(bytes[index + 1])
            else { return nil }
            result.append((high << 4) | low)
            index += 2
        }
        return result
    }

    private static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39:
            return byte - 0x30
        case 0x41...0x46:
            return byte - 0x41 + 10
        case 0x61...0x66:
            return byte - 0x61 + 10
        default:
            return nil
        }
    }

    private static func looksLikeProfileReference(_ raw: String) -> Bool {
        hasCaseInsensitivePrefix(raw, "npub1")
            || hasCaseInsensitivePrefix(raw, "nprofile1")
            || Hex.is32Bytes(raw)
    }

    private static func hasCaseInsensitivePrefix(_ raw: String, _ prefix: String) -> Bool {
        raw.prefix(prefix.count).lowercased() == prefix
    }

    static func isWithinReferenceLimit(_ raw: String) -> Bool {
        raw.utf8.index(
            raw.utf8.startIndex,
            offsetBy: maxBech32ReferenceUTF8Bytes + 1,
            limitedBy: raw.utf8.endIndex
        ) == nil
    }

    private static func bech32Decode(_ raw: String) -> (hrp: String, data: [UInt8])? {
        guard isWithinReferenceLimit(raw) else { return nil }
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

    private static func bech32Encode(hrp: String, data: [UInt8]) -> String? {
        let lowerHrp = hrp.lowercased()
        guard !lowerHrp.isEmpty,
              lowerHrp.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }),
              data.allSatisfy({ $0 < 32 })
        else { return nil }

        let values = data + bech32CreateChecksum(hrp: lowerHrp, values: data)
        let dataPart = values.map { String(bech32Charset[Int($0)]) }.joined()
        return lowerHrp + "1" + dataPart
    }

    private static func bech32CreateChecksum(hrp: String, values: [UInt8]) -> [UInt8] {
        var expanded = bech32HrpExpand(hrp)
        expanded.append(contentsOf: values)
        expanded.append(contentsOf: Array(repeating: UInt8(0), count: 6))
        let polymod = bech32Polymod(expanded) ^ 1
        return (0..<6).map { index in
            UInt8((polymod >> (5 * (5 - index))) & 31)
        }
    }

    private static func bech32VerifyChecksum(hrp: String, values: [UInt8]) -> Bool {
        var expanded = bech32HrpExpand(hrp)
        expanded.append(contentsOf: values)
        return bech32Polymod(expanded) == 1
    }

    private static func bech32HrpExpand(_ hrp: String) -> [UInt8] {
        var expanded: [UInt8] = hrp.unicodeScalars.map { UInt8($0.value >> 5) }
        expanded.append(0)
        expanded.append(contentsOf: hrp.unicodeScalars.map { UInt8($0.value & 31) })
        return expanded
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
