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

/// Keeps action results account-scoped after awaits: a result produced for one
/// account must not be published after the screen has switched to another.
nonisolated enum NotificationSettingsActionApplyPolicy {
    static func canApplyResult(startedFor actionAccountRef: String?, currentAccountRef: String?) -> Bool {
        actionAccountRef == currentAccountRef
    }
}

/// Serializes notification settings actions so only one mutating operation runs
/// at a time. The view disables controls while saving, but each button launches
/// its own async `Task`, so rapid taps or re-entrant calls can still arrive
/// concurrently. This gate is the single source of truth for "is an action in
/// flight": `tryBegin()` returns `false` when one already is, so the caller
/// returns early instead of starting an overlapping mutation. Extracted as a
/// small value type so the re-entrancy contract can be unit tested without an
/// `AppState`.
@MainActor
struct NotificationActionGate {
    private(set) var isRunning = false
    private var generation = 0

    /// Attempts to claim the gate. Returns `true` and marks it running when no
    /// action is in flight; returns `false` when one already is (caller must not
    /// proceed). The check-and-set is a single synchronous step on the MainActor,
    /// so two concurrent tasks cannot both observe `false` and both begin.
    mutating func tryBegin() -> Bool {
        guard !isRunning else { return false }
        generation += 1
        isRunning = true
        return true
    }

    /// Returns a ticket that lets a reload apply only if no action starts before
    /// its awaited reads finish. Reloads do not claim the mutating-action gate,
    /// but stale reload completions are discarded instead of overwriting a newer
    /// action result. `generation` is intentionally bumped on both `tryBegin()`
    /// and `end()` so a ticket issued before an action cannot become valid again
    /// after that action completes.
    func reloadTicket() -> Int? {
        guard !isRunning else { return nil }
        return generation
    }

    func canApplyReload(startedAt ticket: Int) -> Bool {
        !isRunning && generation == ticket
    }

    /// Releases the gate so the next action may begin.
    mutating func end() {
        generation += 1
        isRunning = false
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

    private var actionGate = NotificationActionGate()
    private var reloadRequestedAfterAction = false

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
            } catch {
                let updatedAuthorizationStatus = await appState.notificationAuthorizationStatus()
                guard canApplyActionResult(startedFor: accountRef, using: appState) else { return }
                authorizationStatus = updatedAuthorizationStatus
                Haptics.error()
                errorMessage = error.localizedDescription
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
            } catch {
                let updatedAuthorizationStatus = await appState.notificationAuthorizationStatus()
                guard canApplyActionResult(startedFor: accountRef, using: appState) else { return }
                authorizationStatus = updatedAuthorizationStatus
                Haptics.error()
                errorMessage = error.localizedDescription
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
            } catch {
                let updatedAuthorizationStatus = await appState.notificationAuthorizationStatus()
                guard canApplyActionResult(startedFor: accountRef, using: appState) else { return }
                authorizationStatus = updatedAuthorizationStatus
                Haptics.error()
                errorMessage = error.localizedDescription
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
            } catch {
                let updatedAuthorizationStatus = await appState.notificationAuthorizationStatus()
                guard canApplyActionResult(startedFor: accountRef, using: appState) else { return }
                authorizationStatus = updatedAuthorizationStatus
                Haptics.error()
                errorMessage = error.localizedDescription
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
            } catch {
                guard canApplyActionResult(startedFor: accountRef, using: appState) else { return }
                Haptics.error()
                errorMessage = error.localizedDescription
            }
        }
    }
}
