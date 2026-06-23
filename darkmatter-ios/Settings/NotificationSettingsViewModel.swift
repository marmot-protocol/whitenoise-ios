import Foundation
import UserNotifications
import MarmotKit

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

    /// Attempts to claim the gate. Returns `true` and marks it running when no
    /// action is in flight; returns `false` when one already is (caller must not
    /// proceed). The check-and-set is a single synchronous step on the MainActor,
    /// so two concurrent tasks cannot both observe `false` and both begin.
    mutating func tryBegin() -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        return true
    }

    /// Releases the gate so the next action may begin.
    mutating func end() {
        isRunning = false
    }
}

/// Screen store for `NotificationSettingsView`: owns the notification settings /
/// push-registration / authorization state and the toggle/refresh/sync actions,
/// so the view is pure rendering. The push orchestration lives in AppState's
/// methods (which this calls); the view keeps the reads of `appState.notifications`
/// and the `NativePushServerConfig`-derived footer/sync gate. Methods take
/// `AppState` rather than retaining it.
///
/// All mutating actions are funneled through `runSaving`, which claims a single
/// `NotificationActionGate` before doing any work. This serializes local/native
/// push mutations: a later completion from an older task can no longer overwrite
/// `settings` or `registration` state produced by a newer action, because the
/// newer action never starts while the older one is in flight.
@MainActor
@Observable
final class NotificationSettingsViewModel {
    var settings: NotificationSettingsFfi?
    var registration: PushRegistrationFfi?
    var authorizationStatus: UNAuthorizationStatus = .notDetermined
    var errorMessage: String?
    var savedAt: Date?

    private var actionGate = NotificationActionGate()

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
    private func runSaving(_ body: () async -> Void) async {
        guard actionGate.tryBegin() else { return }
        errorMessage = nil
        defer { actionGate.end() }
        await body()
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
        await runSaving {
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
    }

    func setNativePush(_ enabled: Bool, using appState: AppState) async {
        await runSaving {
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
    }

    func requestApnsToken(using appState: AppState) async {
        await runSaving {
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
    }

    func refreshApnsToken(using appState: AppState) async {
        await runSaving {
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
    }

    func syncNativeRegistration(using appState: AppState) async {
        guard let accountRef = appState.activeAccountRef else { return }
        await runSaving {
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
}
