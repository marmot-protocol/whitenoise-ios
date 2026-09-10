import Foundation
import UserNotifications
import MarmotKit

/// Minimal seam used by `NotificationSettingsViewModel` so account/reload races
/// can be tested without constructing a full `AppState` runtime.
@MainActor
protocol NotificationSettingsViewModelDataSource: AnyObject {
    var activeAccountRef: String? { get }

    func notificationAuthorizationStatus() async -> UNAuthorizationStatus
    func requestNotificationAuthorizationAndRegister() async throws -> Bool
    func refreshNotificationApnsToken() async throws -> String
    func notificationSettings(for accountRef: String) async -> NotificationSettingsFfi?
    func pushRegistration(for accountRef: String) async -> PushRegistrationFfi?
    func setLocalNotificationsEnabled(_ enabled: Bool) async throws -> NotificationSettingsFfi
    func setNativePushEnabled(_ enabled: Bool) async throws -> NotificationSettingsFfi
    func syncNativePushRegistration(accountRef: String) async throws -> PushRegistrationFfi
    func present(_ toast: Toast)
}

extension AppState: NotificationSettingsViewModelDataSource {
    func notificationAuthorizationStatus() async -> UNAuthorizationStatus {
        await notifications.authorizationStatus()
    }

    func requestNotificationAuthorizationAndRegister() async throws -> Bool {
        try await notifications.requestAuthorizationAndRegister()
    }

    func refreshNotificationApnsToken() async throws -> String {
        try await notifications.refreshApnsToken()
    }
}

extension NotificationSettingsViewModelDataSource {
    func present(_ toast: Toast) {}
}

/// Keeps action results account-scoped after awaits: a result produced for one
/// account must not be published after the screen has switched to another.
nonisolated enum NotificationSettingsActionApplyPolicy {
    static func canApplyResult(startedFor actionAccountRef: String?, currentAccountRef: String?) -> Bool {
        actionAccountRef == currentAccountRef
    }
}

/// Screen store for `NotificationSettingsView`: owns the notification settings /
/// push-registration / authorization state and the toggle/refresh/sync actions,
/// so the view is pure rendering. The push orchestration lives in AppState's
/// methods (which this calls); the view keeps the reads of `appState.notifications`
/// and the `NativePushServerConfig`-derived footer/sync gate. Methods take an
/// AppState-compatible data source rather than retaining it.
///
/// All mutating actions are funneled through `runSaving`, which claims a single
/// `NotificationActionGate` before doing any work. Plain reloads take a gate
/// ticket and discard their results if an action starts before their awaited
/// reads finish. Dropped reloads are replayed after the action gate opens again,
/// and action completions only publish state if the active account still matches
/// the account that started the action.
@MainActor
@Observable
final class NotificationSettingsViewModel {
    var settings: NotificationSettingsFfi?
    var registration: PushRegistrationFfi?
    var authorizationStatus: UNAuthorizationStatus = .notDetermined
    var errorMessage: String?
    var savedAt: Date?

    /// Per-device, so it is read from shared defaults rather than from the
    /// account-scoped `settings` this screen otherwise renders.
    var previewMode: NotificationPreviewMode

    private var actionGate = AsyncActionGate()
    private var reloadRequestedAfterAction = false
    private let previewDefaults: UserDefaults?

    /// Tests inject an isolated suite; the shared App Group suite is visible to
    /// every concurrently running suite (and to the extension).
    init(previewDefaults: UserDefaults? = NotificationPreviewStore.defaults) {
        self.previewDefaults = previewDefaults
        previewMode = previewDefaults.map { NotificationPreviewStore.mode(defaults: $0) }
            ?? NotificationPreviewStore.migrationDefault
    }

    /// Publishes storage, not the tap: an unresolvable suite cannot persist the
    /// choice, so the control must keep showing the mode still in force.
    func setPreviewMode(_ mode: NotificationPreviewMode) {
        guard let previewDefaults else { return }
        NotificationPreviewStore.setMode(mode, defaults: previewDefaults)
        previewMode = NotificationPreviewStore.mode(defaults: previewDefaults)
    }

    /// Whether a mutating action is currently in flight. Mirrors the action gate
    /// so the view can disable controls and show progress.
    var isSaving: Bool { actionGate.isRunning }

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

    /// Runs `body` only if no other mutating action is in flight, holding the
    /// action gate for the full duration (including every `await` inside `body`).
    /// Returns early without side effects when an action is already running, so
    /// rapid taps or re-entrant calls cannot start overlapping mutations.
    private func runSaving(
        using appState: any NotificationSettingsViewModelDataSource,
        _ body: () async -> Void
    ) async {
        guard actionGate.tryBegin() else { return }
        errorMessage = nil
        await body()
        actionGate.end()
        await drainDeferredReload(using: appState)
    }

    private func requestReloadAfterAction() {
        reloadRequestedAfterAction = true
    }

    private func drainDeferredReload(using appState: any NotificationSettingsViewModelDataSource) async {
        guard reloadRequestedAfterAction else { return }
        reloadRequestedAfterAction = false
        await reload(using: appState)
    }

    private func deferOrReload(using appState: any NotificationSettingsViewModelDataSource) async {
        if actionGate.isRunning {
            requestReloadAfterAction()
        } else {
            await reload(using: appState)
        }
    }

    private func canApplyActionResult(
        startedFor accountRef: String?,
        using appState: any NotificationSettingsViewModelDataSource
    ) -> Bool {
        guard NotificationSettingsActionApplyPolicy.canApplyResult(
            startedFor: accountRef,
            currentAccountRef: appState.activeAccountRef
        ) else {
            requestReloadAfterAction()
            return false
        }
        return true
    }

    func reload(using appState: any NotificationSettingsViewModelDataSource) async {
        guard let reloadTicket = actionGate.reloadTicket() else {
            requestReloadAfterAction()
            return
        }
        if let previewDefaults {
            previewMode = NotificationPreviewStore.mode(defaults: previewDefaults)
        }
        let accountRef = appState.activeAccountRef
        let reloadedAuthorizationStatus = await appState.notificationAuthorizationStatus()
        guard actionGate.canApplyReload(startedAt: reloadTicket), appState.activeAccountRef == accountRef else {
            await deferOrReload(using: appState)
            return
        }
        authorizationStatus = reloadedAuthorizationStatus
        guard let accountRef else {
            settings = nil
            registration = nil
            return
        }
        let reloadedSettings = await appState.notificationSettings(for: accountRef)
        guard actionGate.canApplyReload(startedAt: reloadTicket), appState.activeAccountRef == accountRef else {
            await deferOrReload(using: appState)
            return
        }
        settings = reloadedSettings
        let reloadedRegistration = await appState.pushRegistration(for: accountRef)
        guard actionGate.canApplyReload(startedAt: reloadTicket), appState.activeAccountRef == accountRef else {
            await deferOrReload(using: appState)
            return
        }
        registration = reloadedRegistration
    }

    func setLocalNotifications(_ enabled: Bool, using appState: any NotificationSettingsViewModelDataSource) async {
        await runSaving(using: appState) {
            let accountRef = appState.activeAccountRef
            do {
                let updatedSettings = try await appState.setLocalNotificationsEnabled(enabled)
                let updatedAuthorizationStatus = await appState.notificationAuthorizationStatus()
                guard canApplyActionResult(startedFor: accountRef, using: appState) else { return }
                settings = updatedSettings
                authorizationStatus = updatedAuthorizationStatus
                savedAt = Date()
                Haptics.success()
                appState.present(.success(L10n.string("Done")))
            } catch {
                let updatedAuthorizationStatus = await appState.notificationAuthorizationStatus()
                guard canApplyActionResult(startedFor: accountRef, using: appState) else { return }
                authorizationStatus = updatedAuthorizationStatus
                Haptics.error()
                appState.present(UserFacingError.toast(
                    title: L10n.string("Notification failed"),
                    error: error
                ))
            }
        }
    }

    func setNativePush(_ enabled: Bool, using appState: any NotificationSettingsViewModelDataSource) async {
        await runSaving(using: appState) {
            let accountRef = appState.activeAccountRef
            do {
                let updatedSettings = try await appState.setNativePushEnabled(enabled)
                let updatedAuthorizationStatus = await appState.notificationAuthorizationStatus()
                let updatedRegistration: PushRegistrationFfi?
                if enabled, let accountRef {
                    updatedRegistration = await appState.pushRegistration(for: accountRef)
                } else {
                    updatedRegistration = nil
                }
                guard canApplyActionResult(startedFor: accountRef, using: appState) else { return }
                settings = updatedSettings
                authorizationStatus = updatedAuthorizationStatus
                if enabled {
                    if let updatedRegistration {
                        registration = updatedRegistration
                    } else if registration?.accountRef != accountRef {
                        registration = nil
                    }
                } else {
                    registration = nil
                }
                savedAt = Date()
                Haptics.success()
                appState.present(.success(L10n.string("Done")))
            } catch {
                let updatedAuthorizationStatus = await appState.notificationAuthorizationStatus()
                guard canApplyActionResult(startedFor: accountRef, using: appState) else { return }
                authorizationStatus = updatedAuthorizationStatus
                Haptics.error()
                appState.present(UserFacingError.toast(
                    title: L10n.string("Notification failed"),
                    error: error
                ))
            }
        }
    }

    func requestApnsToken(using appState: any NotificationSettingsViewModelDataSource) async {
        await runSaving(using: appState) {
            let accountRef = appState.activeAccountRef
            do {
                let granted = try await appState.requestNotificationAuthorizationAndRegister()
                guard granted else { throw NotificationSettingsActionError.permissionDenied }
                let updatedAuthorizationStatus = await appState.notificationAuthorizationStatus()
                guard canApplyActionResult(startedFor: accountRef, using: appState) else { return }
                authorizationStatus = updatedAuthorizationStatus
                savedAt = Date()
                requestReloadAfterAction()
                Haptics.success()
                appState.present(.success(L10n.string("Done")))
            } catch {
                let updatedAuthorizationStatus = await appState.notificationAuthorizationStatus()
                guard canApplyActionResult(startedFor: accountRef, using: appState) else { return }
                authorizationStatus = updatedAuthorizationStatus
                Haptics.error()
                appState.present(UserFacingError.toast(
                    title: L10n.string("Notification failed"),
                    error: error
                ))
            }
        }
    }

    func refreshApnsToken(using appState: any NotificationSettingsViewModelDataSource) async {
        await runSaving(using: appState) {
            let accountRef = appState.activeAccountRef
            do {
                _ = try await appState.refreshNotificationApnsToken()
                let updatedAuthorizationStatus = await appState.notificationAuthorizationStatus()
                guard canApplyActionResult(startedFor: accountRef, using: appState) else { return }
                authorizationStatus = updatedAuthorizationStatus
                savedAt = Date()
                requestReloadAfterAction()
                Haptics.success()
                appState.present(.success(L10n.string("Done")))
            } catch {
                let updatedAuthorizationStatus = await appState.notificationAuthorizationStatus()
                guard canApplyActionResult(startedFor: accountRef, using: appState) else { return }
                authorizationStatus = updatedAuthorizationStatus
                Haptics.error()
                appState.present(UserFacingError.toast(
                    title: L10n.string("Notification failed"),
                    error: error
                ))
            }
        }
    }

    func syncNativeRegistration(using appState: any NotificationSettingsViewModelDataSource) async {
        await runSaving(using: appState) {
            guard let accountRef = appState.activeAccountRef else { return }
            do {
                let updatedRegistration = try await appState.syncNativePushRegistration(accountRef: accountRef)
                guard canApplyActionResult(startedFor: accountRef, using: appState) else { return }
                registration = updatedRegistration
                savedAt = Date()
                Haptics.success()
                appState.present(.success(L10n.string("Done")))
            } catch {
                guard canApplyActionResult(startedFor: accountRef, using: appState) else { return }
                Haptics.error()
                appState.present(UserFacingError.toast(
                    title: L10n.string("Notification failed"),
                    error: error
                ))
            }
        }
    }
}
