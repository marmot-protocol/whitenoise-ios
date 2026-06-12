import Foundation

/// Dark Matter deep links. Formats: `darkmatter://profile/<profile-ref>` and
/// `darkmatter://chat/<groupIdHex>`.
///
/// Used both for the QR codes the app generates and for routing inbound
/// links — whether from the in-app scanner (which reads the raw string) or
/// the system (via `.onOpenURL`, once the URL scheme is registered in
/// Info.plist).
nonisolated enum DeepLink: Equatable {
    /// Profile reference accepted by Marmot. This is usually an `npub`, but
    /// may be hex when the source was an `nprofile` pointer.
    case profile(npub: String)
    case chat(groupIdHex: String)

    static let scheme = "darkmatter"

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
        components.scheme = scheme
        components.host = host
        components.percentEncodedPath = "/" + encodedPathComponent(pathComponent)
        guard let url = components.url else {
            assertionFailure("Failed to build Dark Matter deep link")
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

    /// Parse a `darkmatter://…` URL.
    static func parse(_ url: URL) -> DeepLink? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch url.host?.lowercased() {
        case "profile":
            if let reference = parts.first,
               let memberRef = NostrProfileReference.memberRef(fromReference: reference) {
                return .profile(npub: memberRef)
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
        // Tolerate darkmatter://<profile-ref>
        if let host = url.host,
           let memberRef = NostrProfileReference.memberRef(fromReference: host) {
            return .profile(npub: memberRef)
        }
        return nil
    }

    /// Parse any scanned/pasted string: a deep-link URL, a `nostr:` URI, or a
    /// bare profile reference. Makes the scanner forgiving about QR payload
    /// formats.
    static func parse(string raw: String) -> DeepLink? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let link = parse(url) {
            return link
        }
        if let memberRef = NostrProfileReference.memberRef(from: trimmed) {
            return .profile(npub: memberRef)
        }
        return nil
    }
}
