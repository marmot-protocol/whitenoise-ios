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
    // Avoid the isolated-deinit task-local crash on older Swift runtimes (including iOS 26.2).
    // https://github.com/swiftlang/swift/issues/88036
    nonisolated deinit {}

    var settings: NotificationSettingsFfi?
    var registration: PushRegistrationFfi?
    var authorizationStatus: UNAuthorizationStatus = .notDetermined
    enum Action: Hashable {
        case localNotifications, nativePush, setup
    }

    private(set) var activeAction: Action?
    private(set) var actionErrors: [Action: String] = [:]
    private(set) var hasLoadedAuthorization = false
    private var hasFinishedLoading = false
    private var reloadsInFlight = 0
    private var feedbackAccountRef: String?

    // Keep loaded rows and setup feedback stable during a refresh.
    var isLoading: Bool { !hasFinishedLoading || (settings == nil && reloadsInFlight > 0) }

    /// Per-device, so it is read from shared defaults rather than from the
    /// account-scoped `settings` this screen otherwise renders.
    var previewMode: NotificationPreviewMode
    /// Per-device, like `previewMode`: whether direct mentions still notify
    /// from muted chats.
    var mentionsBreakThroughMute: Bool

    private var actionGate = AsyncActionGate()
    private var reloadRequestedAfterAction = false
    private let previewDefaults: UserDefaults?
    private let mutedChatMentionsDefaults: UserDefaults?

    /// Tests inject isolated suites; the shared App Group suite is visible to
    /// every concurrently running suite (and to the extension).
    init(
        previewDefaults: UserDefaults? = NotificationPreviewStore.defaults,
        mutedChatMentionsDefaults: UserDefaults? = MutedChatMentionsStore.defaults
    ) {
        self.previewDefaults = previewDefaults
        self.mutedChatMentionsDefaults = mutedChatMentionsDefaults
        previewMode = previewDefaults.map { NotificationPreviewStore.mode(defaults: $0) }
            ?? NotificationPreviewStore.migrationDefault
        mentionsBreakThroughMute = mutedChatMentionsDefaults.map {
            MutedChatMentionsStore.mentionsBreakThroughMute(defaults: $0)
        } ?? MutedChatMentionsStore.unresolvableValue
    }

    /// Publishes storage, not the tap: an unresolvable suite cannot persist the
    /// choice, so the control must keep showing the mode still in force.
    func setPreviewMode(_ mode: NotificationPreviewMode) {
        guard let previewDefaults else { return }
        NotificationPreviewStore.setMode(mode, defaults: previewDefaults)
        previewMode = NotificationPreviewStore.mode(defaults: previewDefaults)
    }

    /// Publishes storage, not the tap, like `setPreviewMode`: an unresolvable
    /// suite keeps showing the policy still in force (off).
    func setMentionsBreakThroughMute(_ enabled: Bool) {
        guard let mutedChatMentionsDefaults else { return }
        MutedChatMentionsStore.setMentionsBreakThroughMute(enabled, defaults: mutedChatMentionsDefaults)
        mentionsBreakThroughMute = MutedChatMentionsStore.mentionsBreakThroughMute(
            defaults: mutedChatMentionsDefaults
        )
    }

    /// Whether a mutating action is currently in flight. Mirrors the action gate
    /// so the view can disable controls and show progress.
    var isSaving: Bool { actionGate.isRunning }

    var nativePushToggleUnavailable: Bool {
        guard let settings else { return true }
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
        _ action: Action,
        using appState: any NotificationSettingsViewModelDataSource,
        _ body: () async -> Void
    ) async {
        guard actionGate.tryBegin() else { return }
        prepareFeedback(for: appState.activeAccountRef)
        activeAction = action
        actionErrors[action] = nil
        await body()
        activeAction = nil
        actionGate.end()
        await drainDeferredReload(using: appState)
    }

    private func prepareFeedback(for accountRef: String?) {
        guard feedbackAccountRef != accountRef else { return }
        feedbackAccountRef = accountRef
        actionErrors.removeAll()
    }

    /// The screen also observes APNS token/server availability, including recovery outside a settings action.
    func clearResolvedSetupError() {
        actionErrors[.setup] = nil
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
        prepareFeedback(for: appState.activeAccountRef)
        guard let reloadTicket = actionGate.reloadTicket() else {
            requestReloadAfterAction()
            return
        }
        reloadsInFlight += 1
        defer {
            reloadsInFlight -= 1
        }
        if let previewDefaults {
            previewMode = NotificationPreviewStore.mode(defaults: previewDefaults)
        }
        if let mutedChatMentionsDefaults {
            mentionsBreakThroughMute = MutedChatMentionsStore.mentionsBreakThroughMute(
                defaults: mutedChatMentionsDefaults
            )
        }
        let accountRef = appState.activeAccountRef
        let reloadedAuthorizationStatus = await appState.notificationAuthorizationStatus()
        guard actionGate.canApplyReload(startedAt: reloadTicket), appState.activeAccountRef == accountRef else {
            await deferOrReload(using: appState)
            return
        }
        authorizationStatus = reloadedAuthorizationStatus
        hasLoadedAuthorization = true
        guard let accountRef else {
            settings = nil
            registration = nil
            hasFinishedLoading = true
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
        hasFinishedLoading = true
    }

    func setLocalNotifications(_ enabled: Bool, using appState: any NotificationSettingsViewModelDataSource) async {
        await runSaving(.localNotifications, using: appState) {
            let accountRef = appState.activeAccountRef
            do {
                let updatedSettings = try await appState.setLocalNotificationsEnabled(enabled)
                let updatedAuthorizationStatus = await appState.notificationAuthorizationStatus()
                guard canApplyActionResult(startedFor: accountRef, using: appState) else { return }
                settings = updatedSettings
                authorizationStatus = updatedAuthorizationStatus
                Haptics.success()
            } catch {
                let updatedAuthorizationStatus = await appState.notificationAuthorizationStatus()
                guard canApplyActionResult(startedFor: accountRef, using: appState) else { return }
                authorizationStatus = updatedAuthorizationStatus
                Haptics.error()
                actionErrors[.localNotifications] = UserFacingError.message(for: error)
            }
        }
    }

    func setNativePush(_ enabled: Bool, using appState: any NotificationSettingsViewModelDataSource) async {
        await runSaving(.nativePush, using: appState) {
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
                // Enabling completes registration; disabling makes setup unnecessary.
                actionErrors[.setup] = nil
                Haptics.success()
            } catch {
                let updatedAuthorizationStatus = await appState.notificationAuthorizationStatus()
                guard canApplyActionResult(startedFor: accountRef, using: appState) else { return }
                authorizationStatus = updatedAuthorizationStatus
                Haptics.error()
                actionErrors[.nativePush] = UserFacingError.message(for: error)
            }
        }
    }

    func requestApnsToken(using appState: any NotificationSettingsViewModelDataSource) async {
        await runSaving(.setup, using: appState) {
            let accountRef = appState.activeAccountRef
            do {
                let granted = try await appState.requestNotificationAuthorizationAndRegister()
                guard granted else { throw NotificationSettingsActionError.permissionDenied }
                let updatedAuthorizationStatus = await appState.notificationAuthorizationStatus()
                guard canApplyActionResult(startedFor: accountRef, using: appState) else { return }
                authorizationStatus = updatedAuthorizationStatus
                requestReloadAfterAction()
                Haptics.success()
            } catch {
                let updatedAuthorizationStatus = await appState.notificationAuthorizationStatus()
                guard canApplyActionResult(startedFor: accountRef, using: appState) else { return }
                authorizationStatus = updatedAuthorizationStatus
                Haptics.error()
                actionErrors[.setup] = UserFacingError.message(for: error)
            }
        }
    }

    func refreshApnsToken(using appState: any NotificationSettingsViewModelDataSource) async {
        await runSaving(.setup, using: appState) {
            let accountRef = appState.activeAccountRef
            do {
                _ = try await appState.refreshNotificationApnsToken()
                let updatedAuthorizationStatus = await appState.notificationAuthorizationStatus()
                guard canApplyActionResult(startedFor: accountRef, using: appState) else { return }
                authorizationStatus = updatedAuthorizationStatus
                requestReloadAfterAction()
                Haptics.success()
            } catch {
                let updatedAuthorizationStatus = await appState.notificationAuthorizationStatus()
                guard canApplyActionResult(startedFor: accountRef, using: appState) else { return }
                authorizationStatus = updatedAuthorizationStatus
                Haptics.error()
                actionErrors[.setup] = UserFacingError.message(for: error)
            }
        }
    }

    func syncNativeRegistration(using appState: any NotificationSettingsViewModelDataSource) async {
        await runSaving(.setup, using: appState) {
            guard let accountRef = appState.activeAccountRef else { return }
            do {
                let updatedRegistration = try await appState.syncNativePushRegistration(accountRef: accountRef)
                guard canApplyActionResult(startedFor: accountRef, using: appState) else { return }
                registration = updatedRegistration
                Haptics.success()
            } catch {
                guard canApplyActionResult(startedFor: accountRef, using: appState) else { return }
                Haptics.error()
                actionErrors[.setup] = UserFacingError.message(for: error)
            }
        }
    }
}
