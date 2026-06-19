import Foundation
import Darwin

/// Sanitizes untrusted Nostr profile metadata (kind:0) before it's rendered.
///
/// Anyone can publish any profile to a relay, so every name, avatar URL, and
/// free-text field we display for *another* account is attacker-controlled.
/// This is the rendering boundary: it strips spoofing characters, enforces a
/// URL-scheme allowlist for images, and caps lengths.
///
/// Local profile and group editors also reuse these bounds before publishing
/// metadata so malformed local drafts are not propagated to relays.
nonisolated enum ProfileSanitizer {

    static let maxNameLength = 80
    static let maxGroupNameLength = 100
    static let maxGroupDescriptionLength = 280
    static let maxAboutLength = 1000
    static let maxProfileAddressLength = 254
    static let maxMessageLength = 8000
    static let maxReactionLength = 8

    private static let blankLineRunRegex = try! NSRegularExpression(pattern: "\n{3,}")

    /// Single-line text: strip control/bidi characters, collapse all
    /// whitespace (including newlines) to single spaces, trim, cap length.
    /// Returns nil when nothing renderable remains.
    static func singleLine(_ raw: String?, maxLength: Int) -> String? {
        guard let raw else { return nil }
        let collapsed = stripUnsafe(raw)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maxLength))
    }

    /// Person display name (single line, short cap).
    static func displayName(_ raw: String?) -> String? {
        singleLine(raw, maxLength: maxNameLength)
    }

    /// Group name (single line, slightly longer cap than a person name).
    static func groupName(_ raw: String?) -> String? {
        singleLine(raw, maxLength: maxGroupNameLength)
    }

    /// Multi-line free text (e.g. about): strip control/bidi but keep normal
    /// newlines/tabs, clamp runs of blank lines, trim, cap length.
    static func multilineText(_ raw: String?, maxLength: Int = maxAboutLength) -> String? {
        guard let raw else { return nil }
        // Clamp runs of blank lines so an "about" field can't flood the UI with
        // vertical whitespace (#60), matching the message-body policy.
        let cleaned = clampBlankLineRuns(stripUnsafe(raw))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(maxLength))
    }

    /// Normalize line endings (CRLF and lone CR → LF) then clamp runs of 3+
    /// newlines to a single blank line. Normalizing first means `\r\n` and `\r`
    /// sequences can't slip past the `\n{3,}` clamp.
    private static func clampBlankLineRuns(_ s: String) -> String {
        let normalized = s
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return blankLineRunRegex.stringByReplacingMatches(
            in: normalized,
            range: NSRange(normalized.startIndex..., in: normalized),
            withTemplate: "\n\n"
        )
    }

    /// Message body: multi-line-safe. Strips control/bidi (Trojan-Source
    /// spoofing), preserves newlines for legitimately multi-line messages,
    /// but clamps runs of 3+ blank lines to 2 so a sender can't flood the
    /// timeline with vertical whitespace. Trims outer whitespace and caps
    /// length. Returns "" (not nil) so the bubble renders without optional
    /// handling at the call site.
    static func messageBody(_ raw: String) -> String {
        let trimmed = clampBlankLineRuns(stripUnsafe(raw))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(maxMessageLength))
    }

    /// Strip-only variant for markdown text runs: removes control/bidi/
    /// zero-width characters but does not trim, collapse whitespace, or cap.
    /// Markdown structure owns whitespace, and the markdown builder enforces
    /// the total length budget across all runs of a message.
    static func textRun(_ raw: String) -> String {
        stripUnsafe(raw)
    }

    /// Reaction "emoji" arrive from peers and may not be emoji at all. Strip
    /// spoofing characters (bidi / zero-width / control), trim, and cap length
    /// before display, while preserving legitimate ZWJ and variation-selector
    /// emoji sequences (#70). Non-optional so the reaction chip renders without
    /// optional handling.
    static func reactionEmoji(_ raw: String) -> String {
        let stripped = stripUnsafe(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(stripped.prefix(maxReactionLength))
    }

    /// Image URL allowlist: only HTTPS with a public host. Rejects data:,
    /// file:, javascript:, custom schemes, host-less URLs, and local/private
    /// addresses (including legacy IPv4 literal spellings) so `AsyncImage`
    /// never dereferences something dangerous.
    static func imageURL(_ raw: String?) -> URL? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let comps = URLComponents(string: trimmed),
              let scheme = comps.scheme?.lowercased(),
              scheme == "https",
              let host = comps.host,
              !host.isEmpty,
              !isPrivateOrLoopbackHost(host)
        else { return nil }
        return comps.url
    }

    static func profileAddress(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let collapsed = stripUnsafe(raw)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty, collapsed.count <= maxProfileAddressLength else { return nil }

        let parts = collapsed.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let local = String(parts[0]).lowercased()
        let domain = String(parts[1]).lowercased()
        guard isValidProfileAddressLocalPart(local),
              isValidProfileAddressDomain(domain)
        else { return nil }
        return "\(local)@\(domain)"
    }

    private static func isPrivateOrLoopbackHost(_ host: String) -> Bool {
        let normalized = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        let canonical = strippingTrailingRootDots(normalized)

        if canonical.isEmpty || canonical == "localhost" || canonical == "::1" {
            return true
        }

        if let octets = ipv4Octets(canonical) {
            return isPrivateOrLoopbackIPv4(octets)
        }

        if isLegacyIPv4Literal(canonical) {
            return true
        }

        return isPrivateOrLoopbackIPv6(canonical)
    }

    private static func strippingTrailingRootDots(_ host: String) -> String {
        var canonical = host
        while canonical.hasSuffix(".") {
            canonical.removeLast()
        }
        return canonical
    }

    private static func isPrivateOrLoopbackIPv4(_ octets: [UInt8]) -> Bool {
        guard octets.count == 4 else { return false }

        if octets[0] == 0 || octets[0] == 10 || octets[0] == 127 {
            return true
        }
        if octets[0] == 169 && octets[1] == 254 {
            return true
        }
        if octets[0] == 172 && (16...31).contains(Int(octets[1])) {
            return true
        }
        if octets[0] == 192 && octets[1] == 168 {
            return true
        }
        // RFC 6598 Carrier-Grade-NAT / shared address space: 100.64.0.0/10.
        // The device gateway, captive portal, and internal services often live
        // here on mobile-carrier and CG-NAT networks.
        if octets[0] == 100 && (64...127).contains(Int(octets[1])) {
            return true
        }
        // RFC 6890 IETF protocol assignments: 192.0.0.0/24.
        if octets[0] == 192 && octets[1] == 0 && octets[2] == 0 {
            return true
        }
        // Multicast (224.0.0.0/4) and reserved/future-use (240.0.0.0/4) space,
        // which also covers the 255.255.255.255 limited broadcast address.
        if (224...255).contains(Int(octets[0])) {
            return true
        }
        return false
    }

    private static func ipv4Octets(_ host: String) -> [UInt8]? {
        let pieces = host.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 4 else { return nil }

        var octets: [UInt8] = []
        for piece in pieces {
            guard !piece.isEmpty,
                  !hasAmbiguousLeadingZero(piece),
                  piece.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }),
                  let octet = UInt8(String(piece))
            else { return nil }
            octets.append(octet)
        }
        return octets
    }

    private static func hasAmbiguousLeadingZero(_ value: Substring) -> Bool {
        value.count > 1 && value.first == "0"
    }

    private static func isLegacyIPv4Literal(_ host: String) -> Bool {
        if isIPv4Number(host) {
            return true
        }

        let pieces = host.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count > 1 else { return false }
        return pieces.allSatisfy(isIPv4Number)
    }

    private static func isIPv4Number(_ value: Substring) -> Bool {
        isIPv4Number(String(value))
    }

    private static func isIPv4Number(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        if value.hasPrefix("0x") {
            let hex = value.dropFirst(2)
            return !hex.isEmpty && hex.unicodeScalars.allSatisfy(isASCIIHexDigit)
        }
        return value.unicodeScalars.allSatisfy(isASCIIDigit)
    }

    private static func isASCIIDigit(_ scalar: UnicodeScalar) -> Bool {
        (48...57).contains(scalar.value)
    }

    private static func isASCIIHexDigit(_ scalar: UnicodeScalar) -> Bool {
        (48...57).contains(scalar.value) ||
            (97...102).contains(scalar.value)
    }

    private static func isValidProfileAddressLocalPart(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            isASCIIDigit(scalar) ||
                (97...122).contains(scalar.value) ||
                scalar == "." ||
                scalar == "_" ||
                scalar == "-" ||
                scalar == "+"
        }
    }

    private static func isValidProfileAddressDomain(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.count <= 253,
              value.contains("."),
              !isPrivateOrLoopbackHost(value)
        else { return false }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2,
              let topLevelLabel = labels.last,
              topLevelLabel.unicodeScalars.contains(where: { (97...122).contains($0.value) })
        else { return false }
        return labels.allSatisfy { label in
            guard !label.isEmpty,
                  label.count <= 63,
                  label.first != "-",
                  label.last != "-"
            else { return false }
            return label.unicodeScalars.allSatisfy { scalar in
                isASCIIDigit(scalar) ||
                    (97...122).contains(scalar.value) ||
                    scalar == "-"
            }
        }
    }

    private static func isPrivateOrLoopbackIPv6(_ host: String) -> Bool {
        guard host.contains(":") else { return false }

        let address = String(host.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)[0])
        guard let bytes = ipv6Bytes(address), bytes.count == 16 else { return false }

        if bytes.allSatisfy({ $0 == 0 }) {
            return true
        }

        if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 {
            return true
        }

        let isIPv4Mapped = bytes[0..<10].allSatisfy { $0 == 0 } &&
            bytes[10] == 0xff &&
            bytes[11] == 0xff
        if isIPv4Mapped {
            return isPrivateOrLoopbackIPv4(Array(bytes[12..<16]))
        }

        // SIIT / IPv4-translatable (`::ffff:0:a.b.c.d`, RFC 6052) embeds the
        // IPv4 address in the low 32 bits behind the `::ffff:0:0/96` prefix.
        let isIPv4Translatable = bytes[0..<8].allSatisfy { $0 == 0 } &&
            bytes[8] == 0xff &&
            bytes[9] == 0xff &&
            bytes[10] == 0 &&
            bytes[11] == 0
        if isIPv4Translatable {
            return isPrivateOrLoopbackIPv4(Array(bytes[12..<16]))
        }

        // NAT64 well-known prefix (`64:ff9b::/96`, RFC 6052) also carries the
        // translated IPv4 address in the low 32 bits.
        let isNAT64WellKnown = bytes[0] == 0x00 && bytes[1] == 0x64 &&
            bytes[2] == 0xff && bytes[3] == 0x9b &&
            bytes[4..<12].allSatisfy { $0 == 0 }
        if isNAT64WellKnown {
            return isPrivateOrLoopbackIPv4(Array(bytes[12..<16]))
        }

        // Deprecated IPv4-compatible IPv6 (`::a.b.c.d`) embeds the IPv4
        // address in the low 32 bits without the `::ffff:` marker.
        if bytes[0..<12].allSatisfy({ $0 == 0 }) {
            return isPrivateOrLoopbackIPv4(Array(bytes[12..<16]))
        }

        // Multicast (`ff00::/8`), mirroring the IPv4 multicast/reserved block.
        // Not TCP-connectable, but kept symmetric with the IPv4 side so the
        // allowlist never classifies a multicast group as a public host.
        if bytes[0] == 0xff {
            return true
        }

        // 6to4 (`2002::/16`, RFC 3056) carries the embedded IPv4 in bytes[2..6].
        // `2002:7f00:1::` routes toward 127.0.0.1 on a host with a 6to4
        // pseudo-interface, so re-check the embedded v4 against the private set.
        if bytes[0] == 0x20 && bytes[1] == 0x02 {
            return isPrivateOrLoopbackIPv4(Array(bytes[2..<6]))
        }

        // Teredo (`2001:0000::/32`, RFC 4380) embeds the Teredo server IPv4 in
        // bytes[4..8] (plaintext) and the client IPv4 in bytes[12..16] obfuscated
        // by a bitwise-NOT. Route both through the IPv4 check so a Teredo address
        // pointing at an internal v4 is rejected like the other embeddings.
        if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x00 && bytes[3] == 0x00 {
            if isPrivateOrLoopbackIPv4(Array(bytes[4..<8])) {
                return true
            }
            let teredoClient = bytes[12..<16].map { $0 ^ 0xff }
            return isPrivateOrLoopbackIPv4(teredoClient)
        }

        return (bytes[0] & 0xfe) == 0xfc || (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80)
    }

    private static func ipv6Bytes(_ host: String) -> [UInt8]? {
        var address = in6_addr()
        let parsed = host.withCString { cString in
            withUnsafeMutablePointer(to: &address) { pointer in
                inet_pton(AF_INET6, cString, pointer)
            }
        }
        guard parsed == 1 else { return nil }
        return withUnsafeBytes(of: address) { Array($0) }
    }

    /// Remove Unicode control characters and bidirectional formatting /
    /// override codepoints that can be used to spoof how text renders
    /// (Trojan-Source-style), plus zero-width characters and the BOM.
    ///
    /// Newline / tab / carriage-return are preserved (they're benign
    /// whitespace) so callers can collapse or keep them as appropriate — the
    /// dangerous controls are the *other* C0/C1 codepoints.
    private static func stripUnsafe(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { scalar in
            if scalar == "\n" || scalar == "\t" || scalar == "\r" { return true }
            if scalar.properties.generalCategory == .control { return false }
            switch scalar.value {
            case 0x200E, 0x200F,        // LRM, RLM
                 0x202A...0x202E,       // LRE, RLE, PDF, LRO, RLO
                 0x2066...0x2069,       // LRI, RLI, FSI, PDI
                 0x061C,                // Arabic letter mark
                 0x200B, 0xFEFF:        // zero-width space, BOM / ZWNBSP
                return false
            default:
                return true
            }
        }))
    }
}
