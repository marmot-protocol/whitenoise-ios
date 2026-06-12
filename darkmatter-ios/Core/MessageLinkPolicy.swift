import Foundation

/// What tapping a link inside a message bubble does.
nonisolated enum MessageLinkAction: Equatable {
    case openProfile(npub: String)
    case openChat(groupIdHex: String)
    case confirmExternal(URL)
    case blocked
}

/// Tap-time gate for message links. The markdown builder already refuses to
/// attach disallowed schemes at render time; this second gate decides routing.
nonisolated enum MessageLinkPolicy {

    private static let externalSchemes: Set<String> = [
        "http", "https", "mailto", "tel", "whitenoise", "whitenoise-staging",
    ]

    static func action(for url: URL) -> MessageLinkAction {
        guard let scheme = url.scheme?.lowercased() else { return .blocked }
        switch scheme {
        case DeepLink.scheme, "nostr":
            // DeepLink validates the payload (bech32 checksum for profiles,
            // 32-byte hex for chats); anything that fails stays inert.
            switch DeepLink.parse(string: url.absoluteString) {
            case .profile(let npub):
                return .openProfile(npub: npub)
            case .chat(let groupIdHex):
                return .openChat(groupIdHex: groupIdHex)
            case nil:
                return .blocked
            }
        case _ where externalSchemes.contains(scheme):
            return .confirmExternal(url)
        default:
            return .blocked
        }
    }
}
