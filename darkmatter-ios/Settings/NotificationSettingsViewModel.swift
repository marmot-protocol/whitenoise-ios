import Foundation
import UserNotifications
import MarmotKit

/// Screen store for `NotificationSettingsView`: owns the notification settings /
/// push-registration / authorization state and the toggle/refresh/sync actions,
/// so the view is pure rendering. The push orchestration lives in AppState's
/// methods (which this calls); the view keeps the reads of `appState.notifications`
/// and the `NativePushServerConfig`-derived footer/sync gate. Methods take
/// `AppState` rather than retaining it.
@MainActor
@Observable
final class NotificationSettingsViewModel {
    var settings: NotificationSettingsFfi?
    var registration: PushRegistrationFfi?
    var authorizationStatus: UNAuthorizationStatus = .notDetermined
    var isSaving = false
    var errorMessage: String?
    var savedAt: Date?

    var nativePushToggleDisabled: Bool {
        guard !isSaving, let settings else { return true }
        if settings.nativePushEnabled {
            return false
        }
        return NativePushServerConfig.current() == nil
    }

    var canRefreshApnsToken: Bool {
        guard !isSaving else { return false }
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied, .notDetermined:
            return false
        @unknown default:
            return false
        }
    }

    func reload(using appState: AppState) async {
        authorizationStatus = await appState.notifications.authorizationStatus()
        guard let accountRef = appState.activeAccountRef else {
            settings = nil
            registration = nil
            return
        }
        if let reloadedSettings = await appState.notificationSettings(for: accountRef) {
            settings = reloadedSettings
        }
        if let reloadedRegistration = await appState.pushRegistration(for: accountRef) {
            registration = reloadedRegistration
        }
    }

    func setLocalNotifications(_ enabled: Bool, using appState: AppState) async {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            settings = try await appState.setLocalNotificationsEnabled(enabled)
            savedAt = Date()
            Haptics.success()
            await reload(using: appState)
        } catch {
            Haptics.error()
            errorMessage = error.localizedDescription
        }
    }

    func setNativePush(_ enabled: Bool, using appState: AppState) async {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            settings = try await appState.setNativePushEnabled(enabled)
            savedAt = Date()
            Haptics.success()
            await reload(using: appState)
        } catch {
            Haptics.error()
            errorMessage = error.localizedDescription
        }
    }

    func requestApnsToken(using appState: AppState) async {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            let granted = try await appState.notifications.requestAuthorizationAndRegister()
            guard granted else { throw NotificationSettingsActionError.permissionDenied }
            savedAt = Date()
            await reload(using: appState)
        } catch {
            Haptics.error()
            errorMessage = error.localizedDescription
        }
    }

    func refreshApnsToken(using appState: AppState) async {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            _ = try await appState.notifications.refreshApnsToken()
            savedAt = Date()
            Haptics.success()
            await reload(using: appState)
        } catch {
            Haptics.error()
            errorMessage = error.localizedDescription
            await reload(using: appState)
        }
    }

    func syncNativeRegistration(using appState: AppState) async {
        guard let accountRef = appState.activeAccountRef else { return }
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            registration = try await appState.syncNativePushRegistration(accountRef: accountRef)
            savedAt = Date()
            Haptics.success()
            await reload(using: appState)
        } catch {
            Haptics.error()
            errorMessage = error.localizedDescription
        }
    }
}
