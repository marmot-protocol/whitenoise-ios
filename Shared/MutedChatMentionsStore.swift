import Foundation

/// Per-device choice of whether a direct mention of the receiving account
/// still notifies from a muted chat (a timed mute, Mute → Always, or the
/// per-chat "Nothing" mode — one stored state).
///
/// Lives in the shared App Group suite beside `ChatMuteStore` and
/// `NotificationPreviewStore`, so the main app and the Notification Service
/// Extension apply one policy. Writes happen only from the main app's UI; the
/// extension reads once per wake.
nonisolated enum MutedChatMentionsStore {
    static let storageKey = "notifications.mentionsBreakThroughMute"

    /// What an install with no stored preference gets, including every
    /// existing install at upgrade.
    static let defaultValue = true

    /// What an unresolvable suite reads as. The mute store it pairs with fails
    /// safe (every chat reads as muted), so this must not let mentions through:
    /// a broken suite would otherwise audibly un-mute every muted chat's
    /// mentions.
    static let unresolvableValue = false

    /// The shared App Group suite, or `nil` when it cannot be resolved. Never
    /// fall back to another domain the main app never wrote.
    static var defaults: UserDefaults? {
        UserDefaults(suiteName: AppContainerConfig.appGroupIdentifier)
    }

    static func mentionsBreakThroughMute(defaults: UserDefaults) -> Bool {
        (defaults.object(forKey: storageKey) as? Bool) ?? defaultValue
    }

    /// Resolving read for the main app and the extension.
    static func mentionsBreakThroughMute() -> Bool {
        guard let defaults else { return unresolvableValue }
        return mentionsBreakThroughMute(defaults: defaults)
    }

    static func setMentionsBreakThroughMute(_ enabled: Bool, defaults: UserDefaults) {
        HostSettingsSaveTiming.measure { defaults.set(enabled, forKey: storageKey) }
    }
}
