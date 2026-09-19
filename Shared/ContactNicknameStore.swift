import Foundation

/// Erasure cleanup for retired nickname preferences. Stored values no longer
/// participate in profile, chat, or notification presentation.
nonisolated enum ContactNicknameStore {
    static let storageKey = "contacts.nicknamesByContactKey"

    static var defaults: UserDefaults? {
        UserDefaults(suiteName: AppContainerConfig.appGroupIdentifier)
    }

    /// Removes every nickname authored by one owner account (sign-out cleanup).
    /// The owner hex cannot contain the separator, so the prefix match is exact.
    static func clearAll(
        ownerAccountIdHex: String,
        defaults: UserDefaults? = ContactNicknameStore.defaults
    ) {
        guard let defaults, let owner = normalizedComponent(ownerAccountIdHex) else { return }
        let prefix = "\(owner):"
        var nicknames = defaults.dictionary(forKey: storageKey) ?? [:]
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
