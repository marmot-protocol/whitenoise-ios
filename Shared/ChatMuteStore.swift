import Foundation

/// Per-chat notification delivery mode, mirroring the tri-state control the
/// details screens expose. Raw values are persisted; do not rename cases.
nonisolated enum ChatNotifyMode: String, CaseIterable, Sendable {
    case all
    case mentionsOnly
    case nothing
}

/// Per-device chat mute preference, keyed by (accountIdHex, groupIdHex).
///
/// Shared App Group preferences let the app and notification extension apply
/// the same policy. Timed mutes overlay the delivery mode until their expiry.
nonisolated enum ChatMuteStore {
    static let storageKey = "chats.mutedChatKeys"

    /// The shared App Group suite, or `nil` when it cannot be resolved. A `nil`
    /// suite is a read *failure*, not "no chats muted" — never fall back to
    /// another domain (e.g. `.standard`) that the main app never wrote, because
    /// that reads back empty and silently unmutes every chat. Mute fails *safe*
    /// (treat as muted), the opposite polarity to `localNotificationsEnabled`.
    static var defaults: UserDefaults? {
        UserDefaults(suiteName: AppContainerConfig.appGroupIdentifier)
    }

    /// Composite storage key. Hex components are normalized so callers that
    /// disagree on case or stray whitespace still address the same chat, and
    /// blank or separator-bearing components are rejected so a missing or
    /// malformed account can never mute (or unmute) another account's chats.
    static func key(accountIdHex: String, groupIdHex: String) -> String? {
        guard let account = normalizedComponent(accountIdHex),
              let group = normalizedComponent(groupIdHex)
        else { return nil }
        return "\(account):\(group)"
    }

    private static func storedMutedChatKeys(defaults: UserDefaults) -> Set<String> {
        Set(defaults.stringArray(forKey: storageKey) ?? [])
    }

    static func mutedChatKeys(defaults: UserDefaults, now: Date = .now) -> Set<String> {
        let snapshot = notifyModeSnapshot(defaults: defaults)
        let keys = snapshot.legacyMutedChatKeys
            .union(snapshot.modesByChatKey.keys)
            .union(snapshot.mutedUntilByChatKey.keys)
        return Set(keys.filter { effectiveMode(for: $0, in: snapshot, now: now) == .nothing })
    }

    /// Removes every mute and notify-mode entry the account owns. Called on
    /// destructive sign-out; mirrors `ContactNicknameStore.clearAll`, the
    /// documented sibling this store was missing.
    static func clearAll(accountIdHex: String, defaults: UserDefaults? = ChatMuteStore.defaults) {
        guard let defaults, let account = normalizedComponent(accountIdHex) else { return }
        let prefix = "\(account):"
        let muted = storedMutedChatKeys(defaults: defaults)
        let remainingMuted = muted.filter { !$0.hasPrefix(prefix) }
        if remainingMuted.count != muted.count {
            defaults.set(Array(remainingMuted), forKey: storageKey)
        }
        var modes = (defaults.dictionary(forKey: notifyModeStorageKey) as? [String: String]) ?? [:]
        let ownedModeKeys = modes.keys.filter { $0.hasPrefix(prefix) }
        if !ownedModeKeys.isEmpty {
            for key in ownedModeKeys {
                modes.removeValue(forKey: key)
            }
            defaults.set(modes, forKey: notifyModeStorageKey)
        }
        let deadlines = mutedUntilByChatKey(defaults: defaults).filter { !$0.key.hasPrefix(prefix) }
        defaults.set(deadlines, forKey: mutedUntilStorageKey)
    }

    /// Resolving snapshot for in-app display. A `nil` suite reads as empty here;
    /// the extension uses `mutedChatKeysSnapshot()`, which keeps the failure
    /// distinguishable so the audible path can fail safe.
    static func mutedChatKeys() -> Set<String> {
        guard let defaults else { return [] }
        return mutedChatKeys(defaults: defaults)
    }

    /// Once-per-wake snapshot for the Notification Service Extension. `nil`
    /// signals the shared suite could not be resolved; pair it with
    /// `isMuted(accountIdHex:groupIdHex:snapshot:)`, which treats `nil` as
    /// "all muted".
    static func mutedChatKeysSnapshot() -> Set<String>? {
        guard let defaults else { return nil }
        return mutedChatKeys(defaults: defaults)
    }

    static func isMuted(
        accountIdHex: String,
        groupIdHex: String,
        in mutedChatKeys: Set<String>
    ) -> Bool {
        guard let key = key(accountIdHex: accountIdHex, groupIdHex: groupIdHex) else {
            return false
        }
        return mutedChatKeys.contains(key)
    }

    /// Fail-safe read against a once-per-wake snapshot: a `nil` snapshot means
    /// the shared suite could not be resolved, so the chat is treated as muted.
    static func isMuted(
        accountIdHex: String,
        groupIdHex: String,
        snapshot: Set<String>?
    ) -> Bool {
        guard let snapshot else { return true }
        return isMuted(accountIdHex: accountIdHex, groupIdHex: groupIdHex, in: snapshot)
    }

    /// Resolving read for the main app. A `nil` suite fails safe (muted).
    static func isMuted(accountIdHex: String, groupIdHex: String) -> Bool {
        isMuted(
            accountIdHex: accountIdHex,
            groupIdHex: groupIdHex,
            snapshot: mutedChatKeysSnapshot()
        )
    }

    static func isMuted(
        accountIdHex: String,
        groupIdHex: String,
        defaults: UserDefaults
    ) -> Bool {
        isMuted(
            accountIdHex: accountIdHex,
            groupIdHex: groupIdHex,
            in: mutedChatKeys(defaults: defaults)
        )
    }

    /// Mute writes route through the tri-state writer so the two stores can
    /// never disagree: muting is `.nothing`, unmuting is `.all`.
    static func setMuted(
        _ muted: Bool,
        accountIdHex: String,
        groupIdHex: String,
        defaults: UserDefaults
    ) {
        setNotifyMode(muted ? .nothing : .all, accountIdHex: accountIdHex, groupIdHex: groupIdHex, defaults: defaults)
    }

    /// Resolving write. No-op when the shared suite can't be resolved.
    static func setMuted(_ muted: Bool, accountIdHex: String, groupIdHex: String) {
        guard let defaults else { return }
        setMuted(muted, accountIdHex: accountIdHex, groupIdHex: groupIdHex, defaults: defaults)
    }

    private static func writeLegacyMuted(
        _ muted: Bool,
        key: String,
        defaults: UserDefaults
    ) {
        var keys = storedMutedChatKeys(defaults: defaults)
        if muted {
            keys.insert(key)
        } else {
            keys.remove(key)
        }
        defaults.set(keys.sorted(), forKey: storageKey)
    }

    // MARK: - Tri-state notify mode

    static let notifyModeStorageKey = "chats.notifyModeByChatKey"
    static let mutedUntilStorageKey = "chats.mutedUntilByChatKey"

    private static func mutedUntilByChatKey(defaults: UserDefaults) -> [String: Double] {
        (defaults.dictionary(forKey: mutedUntilStorageKey) as? [String: Double]) ?? [:]
    }

    /// Once-per-wake snapshot for the extension: the mode map plus the legacy
    /// mute set it inherits from.
    struct NotifyModeSnapshot {
        let modesByChatKey: [String: String]
        let legacyMutedChatKeys: Set<String>
        var mutedUntilByChatKey: [String: Double] = [:]
    }

    /// `nil` signals the shared suite could not be resolved; readers fail safe
    /// (treat as `.nothing`), the mute snapshot's polarity.
    static func notifyModeSnapshot() -> NotifyModeSnapshot? {
        guard let defaults else { return nil }
        return notifyModeSnapshot(defaults: defaults)
    }

    static func notifyModeSnapshot(defaults: UserDefaults) -> NotifyModeSnapshot {
        NotifyModeSnapshot(
            modesByChatKey: (defaults.dictionary(forKey: notifyModeStorageKey) as? [String: String]) ?? [:],
            legacyMutedChatKeys: storedMutedChatKeys(defaults: defaults),
            mutedUntilByChatKey: mutedUntilByChatKey(defaults: defaults)
        )
    }

    /// A chat with no explicit mode inherits its legacy mute state — an
    /// already-muted chat reads as `.nothing`, everything else as `.all` — so
    /// the tri-state control needs no one-shot migration pass.
    static func notifyMode(
        accountIdHex: String,
        groupIdHex: String,
        in snapshot: NotifyModeSnapshot,
        now: Date = .now
    ) -> ChatNotifyMode {
        guard let key = key(accountIdHex: accountIdHex, groupIdHex: groupIdHex) else { return .all }
        return effectiveMode(for: key, in: snapshot, now: now)
    }

    private static func effectiveMode(for key: String, in snapshot: NotifyModeSnapshot, now: Date) -> ChatNotifyMode {
        if let deadline = snapshot.mutedUntilByChatKey[key], deadline > now.timeIntervalSince1970 {
            return .nothing
        }
        if let raw = snapshot.modesByChatKey[key], let mode = ChatNotifyMode(rawValue: raw) {
            return mode
        }
        return snapshot.legacyMutedChatKeys.contains(key) ? .nothing : .all
    }

    static func notifyMode(
        accountIdHex: String,
        groupIdHex: String,
        snapshot: NotifyModeSnapshot?,
        now: Date = .now
    ) -> ChatNotifyMode {
        guard let snapshot else { return .nothing }
        return notifyMode(accountIdHex: accountIdHex, groupIdHex: groupIdHex, in: snapshot, now: now)
    }

    /// Resolving read for the main app. A `nil` suite fails safe (`.nothing`).
    static func notifyMode(accountIdHex: String, groupIdHex: String) -> ChatNotifyMode {
        notifyMode(accountIdHex: accountIdHex, groupIdHex: groupIdHex, snapshot: notifyModeSnapshot())
    }

    /// Writes the mode and keeps the legacy mute set consistent (`.nothing`
    /// mutes, anything else unmutes) so mute readers agree with the tri-state
    /// control.
    static func setNotifyMode(
        _ mode: ChatNotifyMode,
        accountIdHex: String,
        groupIdHex: String,
        defaults: UserDefaults
    ) {
        guard let key = key(accountIdHex: accountIdHex, groupIdHex: groupIdHex) else { return }
        var modes = (defaults.dictionary(forKey: notifyModeStorageKey) as? [String: String]) ?? [:]
        modes[key] = mode.rawValue
        defaults.set(modes, forKey: notifyModeStorageKey)
        writeLegacyMuted(mode == .nothing, key: key, defaults: defaults)
        var deadlines = mutedUntilByChatKey(defaults: defaults)
        deadlines.removeValue(forKey: key)
        defaults.set(deadlines, forKey: mutedUntilStorageKey)
    }

    static func setTimedMute(
        until deadline: Date,
        accountIdHex: String,
        groupIdHex: String,
        defaults: UserDefaults
    ) {
        guard let key = key(accountIdHex: accountIdHex, groupIdHex: groupIdHex) else { return }
        var deadlines = mutedUntilByChatKey(defaults: defaults)
        deadlines[key] = deadline.timeIntervalSince1970
        defaults.set(deadlines, forKey: mutedUntilStorageKey)
        // Preserve mentions-only after expiry; an indefinite mute is replaced.
        var modes = (defaults.dictionary(forKey: notifyModeStorageKey) as? [String: String]) ?? [:]
        if modes[key] != ChatNotifyMode.mentionsOnly.rawValue {
            modes[key] = ChatNotifyMode.all.rawValue
        }
        defaults.set(modes, forKey: notifyModeStorageKey)
        writeLegacyMuted(false, key: key, defaults: defaults)
    }

    static func muteExpiry(
        accountIdHex: String,
        groupIdHex: String,
        in snapshot: NotifyModeSnapshot,
        now: Date = .now
    ) -> Date? {
        guard let key = key(accountIdHex: accountIdHex, groupIdHex: groupIdHex),
              let deadline = snapshot.mutedUntilByChatKey[key], deadline > now.timeIntervalSince1970
        else { return nil }
        return Date(timeIntervalSince1970: deadline)
    }

    static func nextMuteExpiry(
        accountIdHex: String,
        in snapshot: NotifyModeSnapshot,
        now: Date = .now
    ) -> Date? {
        guard let account = normalizedComponent(accountIdHex) else { return nil }
        return snapshot.mutedUntilByChatKey
            .filter { $0.key.hasPrefix("\(account):") && $0.value > now.timeIntervalSince1970 }
            .values.min().map { Date(timeIntervalSince1970: $0) }
    }

    /// Resolving write. No-op when the shared suite can't be resolved.
    static func setNotifyMode(_ mode: ChatNotifyMode, accountIdHex: String, groupIdHex: String) {
        guard let defaults else { return }
        setNotifyMode(mode, accountIdHex: accountIdHex, groupIdHex: groupIdHex, defaults: defaults)
    }

    /// Normalizes a key component and rejects blank or separator-bearing input.
    /// The `:` guard keeps the `account:group` join unambiguous at this
    /// documented trust boundary — without it, `("aa:bb", "cc")` and
    /// `("aa", "bb:cc")` would collide on the same key.
    private static func normalizedComponent(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, !trimmed.contains(":") else { return nil }
        return trimmed
    }
}
