import Foundation

/// Private, per-device contact nicknames keyed by (owner accountIdHex,
/// contact accountIdHex). These are user-authored UI preferences, not cached
/// protocol data — the profile directory stays the source of truth when no
/// nickname is set, and nothing stored here is ever published.
///
/// Like `ChatMuteStore`, the map lives in the shared App Group defaults so the
/// Notification Service Extension resolves the same nicknames when rendering
/// sender names. Writes happen only from the main app's UI; the extension
/// reads a snapshot once per wake.
nonisolated enum ContactNicknameStore {
    static let storageKey = "contacts.nicknamesByContactKey"

    /// The shared App Group suite, or `nil` when it cannot be resolved. Never
    /// fall back to `.standard`: the app and extension have different standard
    /// domains, so that would silently lose cross-process nickname state.
    static var defaults: UserDefaults? {
        UserDefaults(suiteName: AppContainerConfig.appGroupIdentifier)
    }

    /// Composite storage key. Hex components are normalized so callers that
    /// disagree on case or stray whitespace still address the same contact,
    /// and blank components are rejected so a missing account can never read
    /// (or write) another account's nicknames.
    static func key(ownerAccountIdHex: String, contactAccountIdHex: String) -> String? {
        guard let owner = normalizedComponent(ownerAccountIdHex),
              let contact = normalizedComponent(contactAccountIdHex)
        else { return nil }
        return "\(owner):\(contact)"
    }

    static func nicknamesByKey(defaults: UserDefaults? = ContactNicknameStore.defaults) -> [String: String] {
        guard let defaults else { return [:] }
        return (defaults.dictionary(forKey: storageKey) ?? [:]).compactMapValues { $0 as? String }
    }

    /// Stored values are re-sanitized on read so a tampered or legacy defaults
    /// entry can never render an unsanitized name.
    static func nickname(
        ownerAccountIdHex: String,
        contactAccountIdHex: String,
        in nicknamesByKey: [String: String]
    ) -> String? {
        guard let key = key(ownerAccountIdHex: ownerAccountIdHex, contactAccountIdHex: contactAccountIdHex) else {
            return nil
        }
        return ContentSanitizer.displayName(nicknamesByKey[key])
    }

    static func nickname(
        ownerAccountIdHex: String,
        contactAccountIdHex: String,
        defaults: UserDefaults? = ContactNicknameStore.defaults
    ) -> String? {
        nickname(
            ownerAccountIdHex: ownerAccountIdHex,
            contactAccountIdHex: contactAccountIdHex,
            in: nicknamesByKey(defaults: defaults)
        )
    }

    /// Sets or clears a nickname. The raw value goes through the display-name
    /// sanitizer; anything it rejects (empty, whitespace/control-only) clears
    /// the stored entry, so "save an empty field" is the remove gesture.
    static func setNickname(
        _ rawNickname: String?,
        ownerAccountIdHex: String,
        contactAccountIdHex: String,
        defaults: UserDefaults? = ContactNicknameStore.defaults
    ) {
        guard let defaults,
              let key = key(ownerAccountIdHex: ownerAccountIdHex, contactAccountIdHex: contactAccountIdHex)
        else {
            return
        }
        var nicknames = nicknamesByKey(defaults: defaults)
        if let nickname = ContentSanitizer.displayName(rawNickname) {
            nicknames[key] = nickname
        } else {
            nicknames.removeValue(forKey: key)
        }
        defaults.set(nicknames, forKey: storageKey)
    }

    /// Removes every nickname authored by one owner account (sign-out cleanup).
    /// The owner hex cannot contain the separator, so the prefix match is exact.
    static func clearAll(
        ownerAccountIdHex: String,
        defaults: UserDefaults? = ContactNicknameStore.defaults
    ) {
        guard let defaults, let owner = normalizedComponent(ownerAccountIdHex) else { return }
        let prefix = "\(owner):"
        var nicknames = nicknamesByKey(defaults: defaults)
        let ownedKeys = nicknames.keys.filter { $0.hasPrefix(prefix) }
        guard !ownedKeys.isEmpty else { return }
        for key in ownedKeys {
            nicknames.removeValue(forKey: key)
        }
        defaults.set(nicknames, forKey: storageKey)
    }

    private static func normalizedComponent(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }
}
