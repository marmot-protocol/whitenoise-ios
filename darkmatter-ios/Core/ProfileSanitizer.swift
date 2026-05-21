import Foundation

/// Sanitizes untrusted Nostr profile metadata (kind:0) before it's rendered.
///
/// Anyone can publish any profile to a relay, so every name, avatar URL, and
/// free-text field we display for *another* account is attacker-controlled.
/// This is the rendering boundary: it strips spoofing characters, enforces a
/// URL-scheme allowlist for images, and caps lengths.
///
/// The local user's *own* profile in the editor deliberately bypasses this so
/// they can round-trip their real values; sanitization applies only on the
/// display path.
enum ProfileSanitizer {

    static let maxNameLength = 80
    static let maxGroupNameLength = 100
    static let maxAboutLength = 1000
    static let maxMessageLength = 8000

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
    /// newlines/tabs, trim, cap length.
    static func multilineText(_ raw: String?, maxLength: Int = maxAboutLength) -> String? {
        guard let raw else { return nil }
        let cleaned = stripUnsafe(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(maxLength))
    }

    /// Message body: multi-line-safe. Strips control/bidi (Trojan-Source
    /// spoofing), preserves newlines for legitimately multi-line messages,
    /// but clamps runs of 3+ blank lines to 2 so a sender can't flood the
    /// timeline with vertical whitespace. Trims outer whitespace and caps
    /// length. Returns "" (not nil) so the bubble renders without optional
    /// handling at the call site.
    static func messageBody(_ raw: String) -> String {
        let stripped = stripUnsafe(raw)
        let clamped = stripped.replacingOccurrences(
            of: "\n{3,}",
            with: "\n\n",
            options: .regularExpression
        )
        let trimmed = clamped.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(maxMessageLength))
    }

    /// Image URL allowlist: only http(s) with a host. Rejects data:, file:,
    /// javascript:, custom schemes, and host-less URLs so `AsyncImage` never
    /// dereferences something dangerous.
    static func imageURL(_ raw: String?) -> URL? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let comps = URLComponents(string: trimmed),
              let scheme = comps.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = comps.host,
              !host.isEmpty
        else { return nil }
        return comps.url
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
