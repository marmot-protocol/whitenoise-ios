import Foundation

/// Per-device notification preview preference.
///
/// Lock-screen exposure is a property of the device, not of an account, so one
/// preference covers every signed-in account — and it lives in the shared App
/// Group defaults, the suite `ChatMuteStore` and `AppLanguage` use, so the main
/// app and the Notification Service Extension apply one policy. Writes happen
/// only from the main app's UI; the extension reads once per wake.
nonisolated enum NotificationPreviewStore {
    static let storageKey = "notifications.previewMode"

    /// What an install with no stored preference gets, including every existing
    /// install at upgrade: reveal nothing until the user asks for more.
    static let migrationDefault: NotificationPreviewMode = .generic

    /// The shared App Group suite, or `nil` when it cannot be resolved. Never
    /// fall back to another domain the main app never wrote — that reads back
    /// empty and silently discards the user's choice.
    static var defaults: UserDefaults? {
        UserDefaults(suiteName: AppContainerConfig.appGroupIdentifier)
    }

    static func mode(defaults: UserDefaults) -> NotificationPreviewMode {
        guard let raw = defaults.string(forKey: storageKey),
              let mode = NotificationPreviewMode(rawValue: raw)
        else { return migrationDefault }
        return mode
    }

    /// Resolving read for the main app and the extension. An unresolvable
    /// suite fails safe to the most private mode, which is also the migration
    /// default, so a broken suite can never widen exposure.
    static func mode() -> NotificationPreviewMode {
        guard let defaults else { return migrationDefault }
        return mode(defaults: defaults)
    }

    static func setMode(_ mode: NotificationPreviewMode, defaults: UserDefaults) {
        defaults.set(mode.rawValue, forKey: storageKey)
    }

    /// Resolving write. No-op when the shared suite can't be resolved.
    static func setMode(_ mode: NotificationPreviewMode) {
        guard let defaults else { return }
        setMode(mode, defaults: defaults)
    }
}
