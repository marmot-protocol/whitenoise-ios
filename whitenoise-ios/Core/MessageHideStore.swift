import Foundation

/// Per-device "Delete for me" state. Message ids are scoped to the local
/// account and conversation and are never published through Marmot.
nonisolated enum MessageHideStore {
    static let storageKey = "messages.hiddenMessageIdsByConversation"
    private static let storageLock = NSLock()

    static var defaults: UserDefaults? {
        UserDefaults(suiteName: AppContainerConfig.appGroupIdentifier)
    }

    static func conversationKey(accountRef: String, groupIdHex: String) -> String? {
        guard let account = normalizedAccountRef(accountRef),
              let group = Hex.normalizedGroupIdHex(groupIdHex)
        else { return nil }
        return "\(account.utf8.count):\(account):\(group)"
    }

    static func hiddenMessageIds(
        accountRef: String,
        groupIdHex: String,
        defaults: UserDefaults? = MessageHideStore.defaults
    ) -> Set<String> {
        guard let defaults,
              let key = conversationKey(accountRef: accountRef, groupIdHex: groupIdHex)
        else { return [] }
        return withStorageLock {
            Set(hiddenMessageIdsByConversation(defaults: defaults)[key] ?? [])
        }
    }

    @discardableResult
    static func hideMessage(
        accountRef: String,
        groupIdHex: String,
        messageIdHex: String,
        defaults: UserDefaults? = MessageHideStore.defaults
    ) -> Set<String> {
        guard let defaults,
              let key = conversationKey(accountRef: accountRef, groupIdHex: groupIdHex),
              let messageId = Hex.normalized32Bytes(messageIdHex)
        else { return [] }

        return withStorageLock {
            var entries = hiddenMessageIdsByConversation(defaults: defaults)
            var hidden = Set(entries[key] ?? [])
            hidden.insert(messageId)
            entries[key] = hidden.sorted()
            defaults.set(entries, forKey: storageKey)
            return hidden
        }
    }

    /// Removes local-hide state only when the identity itself is destructively
    /// wiped. A normal sign-out preserves it for later account reactivation.
    static func clearAll(
        accountRef: String,
        defaults: UserDefaults? = MessageHideStore.defaults
    ) {
        guard let defaults, let prefix = accountKeyPrefix(accountRef) else { return }
        withStorageLock {
            var entries = hiddenMessageIdsByConversation(defaults: defaults)
            let keys = entries.keys.filter { $0.hasPrefix(prefix) }
            guard !keys.isEmpty else { return }
            for key in keys {
                entries.removeValue(forKey: key)
            }
            defaults.set(entries, forKey: storageKey)
        }
    }

    private static func hiddenMessageIdsByConversation(defaults: UserDefaults) -> [String: [String]] {
        (defaults.dictionary(forKey: storageKey) ?? [:]).compactMapValues { value in
            guard let ids = value as? [String] else { return nil }
            let normalized = Set(ids.compactMap { Hex.normalized32Bytes($0) })
            return normalized.isEmpty ? nil : normalized.sorted()
        }
    }

    private static func accountKeyPrefix(_ accountRef: String) -> String? {
        guard let account = normalizedAccountRef(accountRef) else { return nil }
        return "\(account.utf8.count):\(account):"
    }

    private static func normalizedAccountRef(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func withStorageLock<T>(_ operation: () -> T) -> T {
        storageLock.lock()
        defer { storageLock.unlock() }
        return operation()
    }

}
