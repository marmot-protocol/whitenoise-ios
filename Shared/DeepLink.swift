import Foundation

/// App deep links. Formats: `<scheme>://profile/<profile-ref>` and
/// `<scheme>://chat/<groupIdHex>`.
///
/// Generation always uses the canonical `marmot` scheme — shared QR/link
/// content is environment-independent, so the flavor scheme would only make
/// other Marmot clients reject it. Inbound routing stays scheme-liberal:
/// the in-app scanner reads the raw string, and the system delivers only the
/// flavor schemes registered in Info.plist via `.onOpenURL`.
nonisolated enum DeepLink: Equatable {
    /// Profile reference accepted by Marmot. This is usually an `npub`, but
    /// may be hex or `nprofile` when the source includes relay hints.
    case profile(npub: String)
    case chat(groupIdHex: String)

    /// Canonical scheme for generated links, independent of build flavor.
    static let canonicalScheme = "marmot"

    /// The URL scheme is flavor-specific (`marmot` vs. `marmot-staging`) so
    /// side-by-side installs route their own links.
    /// Read from the Info.plist `WNURLScheme` key (`$(WN_URL_SCHEME)`),
    /// falling back to production.
    static let scheme: String =
        (Bundle.main.object(forInfoDictionaryKey: "WNURLScheme") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        ?? "marmot"

    /// Legacy flavor-specific White Noise scheme. Registered so existing
    /// links continue opening the app, but new generated links use `scheme`.
    static let legacyScheme: String =
        (Bundle.main.object(forInfoDictionaryKey: "WNLegacyURLScheme") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        ?? "whitenoise"

    private static let knownInteropSchemes: Set<String> = [
        "marmot", "marmot-staging",
        "whitenoise", "whitenoise-staging",
    ]

    static func isKnownInteropScheme(_ value: String?) -> Bool {
        guard let value else { return false }
        return isCurrentAppScheme(value) || knownInteropSchemes.contains(value.lowercased())
    }

    static func isCurrentAppScheme(_ value: String?) -> Bool {
        guard let value else { return false }
        let lowercased = value.lowercased()
        return lowercased == scheme.lowercased()
            || lowercased == legacyScheme.lowercased()
    }

    var url: URL {
        switch self {
        case .profile(let npub):
            return Self.url(host: "profile", pathComponent: npub)
        case .chat(let groupIdHex):
            return Self.url(host: "chat", pathComponent: groupIdHex)
        }
    }

    private static func url(host: String, pathComponent: String) -> URL {
        var components = URLComponents()
        components.scheme = canonicalScheme
        components.host = host
        components.percentEncodedPath = "/" + encodedPathComponent(pathComponent)
        guard let url = components.url else {
            assertionFailure("Failed to build Marmot deep link")
            return URL(fileURLWithPath: "/")
        }
        return url
    }

    private static func encodedPathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: pathComponentAllowed) ?? ""
    }

    private static let pathComponentAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    /// Parse a Marmot/legacy White Noise app URL.
    static func parse(_ url: URL) -> DeepLink? {
        guard isKnownInteropScheme(url.scheme) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch url.host?.lowercased() {
        case "profile":
            if let reference = parts.first,
               let resolutionReference = NostrProfileReference.referenceForResolution(fromReference: reference) {
                return .profile(npub: resolutionReference)
            }
        case "chat":
            // A Marmot group id is a 32-byte (64-char) hex value. Reject any
            // other length before routing it to Marmot (#68).
            if let id = parts.first, let groupId = Hex.normalized32Bytes(id) {
                return .chat(groupIdHex: groupId)
            }
        default:
            break
        }
        // Tolerate <scheme>://<profile-ref>
        if let host = url.host,
           let resolutionReference = NostrProfileReference.referenceForResolution(fromReference: host) {
            return .profile(npub: resolutionReference)
        }
        return nil
    }

    /// Parse any scanned/pasted string: a deep-link URL, a `nostr:` URI, or a
    /// bare profile reference. Makes the scanner forgiving about QR payload
    /// formats.
    static func parse(string raw: String) -> DeepLink? {
        guard NostrProfileReference.isWithinReferenceLimit(raw) else { return nil }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let resolutionReference = NostrProfileReference.referenceForResolution(from: trimmed) {
            return .profile(npub: resolutionReference)
        }
        if let url = URL(string: trimmed), let link = parse(url) {
            return link
        }
        return nil
    }
}
