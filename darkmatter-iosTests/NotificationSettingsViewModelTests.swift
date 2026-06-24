import Foundation
import MarmotKit
import Testing
import UserNotifications
@testable import darkmatter_ios

/// Focused coverage for the re-entrancy contract behind `NotificationSettingsViewModel`.
/// The view model funnels every mutating action through `NotificationActionGate`, so
/// these tests pin the gate's serialization guarantee directly — no `AppState` needed.
@MainActor
struct NotificationActionGateTests {
    @Test func tryBeginSucceedsWhenIdle() {
        var gate = NotificationActionGate()
        #expect(gate.isRunning == false)
        #expect(gate.tryBegin() == true)
        #expect(gate.isRunning == true)
    }

    @Test func tryBeginRejectsWhileRunning() {
        var gate = NotificationActionGate()
        #expect(gate.tryBegin() == true)
        // A second action arriving while the first is in flight must be rejected,
        // so it cannot start an overlapping mutation.
        #expect(gate.tryBegin() == false)
        #expect(gate.isRunning == true)
    }

    @Test func endReleasesGateForNextAction() {
        var gate = NotificationActionGate()
        #expect(gate.tryBegin() == true)
        gate.end()
        #expect(gate.isRunning == false)
        // Once released, a subsequent action may claim the gate again.
        #expect(gate.tryBegin() == true)
    }

    @Test func repeatedRejectionsDoNotReleaseTheGate() {
        var gate = NotificationActionGate()
        #expect(gate.tryBegin() == true)
        // Rapid repeated taps each fail and leave the in-flight action's claim intact.
        #expect(gate.tryBegin() == false)
        #expect(gate.tryBegin() == false)
        #expect(gate.isRunning == true)
        // Only the original action's completion releases it.
        gate.end()
        #expect(gate.isRunning == false)
    }

    @Test func reloadTicketIsUnavailableWhileActionIsRunning() {
        var gate = NotificationActionGate()
        #expect(gate.tryBegin() == true)
        #expect(gate.reloadTicket() == nil)
    }

    @Test func actionStartInvalidatesExistingReloadTicket() {
        var gate = NotificationActionGate()
        let ticket = gate.reloadTicket()
        #expect(ticket != nil)
        #expect(gate.canApplyReload(startedAt: ticket!) == true)

        #expect(gate.tryBegin() == true)
        #expect(gate.canApplyReload(startedAt: ticket!) == false)
        gate.end()
        #expect(gate.canApplyReload(startedAt: ticket!) == false)
    }
}

/// Verifies the view model exposes the gate's state through `isSaving`, which the
/// view reads to disable controls while an action is in flight.
@MainActor
struct NotificationSettingsViewModelTests {
    @Test func isSavingDefaultsToFalse() {
        let model = NotificationSettingsViewModel()
        #expect(model.isSaving == false)
    }

    @Test func nativePushToggleDisabledWhenSettingsMissing() {
        let model = NotificationSettingsViewModel()
        // No settings loaded yet -> the native push toggle stays disabled.
        #expect(model.nativePushToggleDisabled == true)
    }

    @Test func canRefreshApnsTokenFalseWhenNotDetermined() {
        let model = NotificationSettingsViewModel()
        // Authorization defaults to .notDetermined -> refresh is gated off.
        #expect(model.canRefreshApnsToken == false)
    }

    @Test func reloadClearsMissingSettingsAndRegistrationForActiveAccount() async {
        let model = NotificationSettingsViewModel()
        let dataSource = NotificationSettingsViewModelDataSourceStub(activeAccountRef: "account-b")
        model.settings = notificationSettings(accountRef: "account-a")
        model.registration = pushRegistration(accountRef: "account-a")

        await model.reload(using: dataSource)

        #expect(model.settings == nil)
        #expect(model.registration == nil)
    }

    @Test func accountSwitchDuringActionReplaysReloadInsteadOfPublishingOldAccountResult() async {
        let model = NotificationSettingsViewModel()
        let dataSource = NotificationSettingsViewModelDataSourceStub(activeAccountRef: "account-a")
        let currentAccountSettings = notificationSettings(
            accountRef: "account-b",
            localNotificationsEnabled: false,
            nativePushEnabled: true
        )
        let currentAccountRegistration = pushRegistration(accountRef: "account-b")
        dataSource.settingsByAccount["account-b"] = currentAccountSettings
        dataSource.registrationsByAccount["account-b"] = currentAccountRegistration

        let actionTask = Task { @MainActor in
            await model.setLocalNotifications(true, using: dataSource)
        }
        await dataSource.waitUntilSetLocalNotificationsStarted()

        dataSource.activeAccountRef = "account-b"
        await model.reload(using: dataSource)
        dataSource.completeSetLocalNotifications(
            with: notificationSettings(accountRef: "account-a", localNotificationsEnabled: true)
        )
        await actionTask.value

        #expect(model.settings == currentAccountSettings)
        #expect(model.registration == currentAccountRegistration)
        #expect(model.savedAt == nil)
    }
}

@MainActor
private final class NotificationSettingsViewModelDataSourceStub: NotificationSettingsViewModelDataSource {
    var activeAccountRef: String?
    var authorizationStatus: UNAuthorizationStatus = .authorized
    var settingsByAccount: [String: NotificationSettingsFfi] = [:]
    var registrationsByAccount: [String: PushRegistrationFfi] = [:]

    private var setLocalNotificationsStarted = false
    private var setLocalNotificationsStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var setLocalNotificationsContinuation: CheckedContinuation<NotificationSettingsFfi, Error>?

    init(activeAccountRef: String?) {
        self.activeAccountRef = activeAccountRef
    }

    func notificationAuthorizationStatus() async -> UNAuthorizationStatus {
        authorizationStatus
    }

    func requestNotificationAuthorizationAndRegister() async throws -> Bool {
        true
    }

    func refreshNotificationApnsToken() async throws -> String {
        "apns-token"
    }

    func notificationSettings(for accountRef: String) async -> NotificationSettingsFfi? {
        settingsByAccount[accountRef]
    }

    func pushRegistration(for accountRef: String) async -> PushRegistrationFfi? {
        registrationsByAccount[accountRef]
    }

    func setLocalNotificationsEnabled(_ _: Bool) async throws -> NotificationSettingsFfi {
        setLocalNotificationsStarted = true
        setLocalNotificationsStartWaiters.forEach { $0.resume() }
        setLocalNotificationsStartWaiters.removeAll()
        return try await withCheckedThrowingContinuation { continuation in
            setLocalNotificationsContinuation = continuation
        }
    }

    func setNativePushEnabled(_ enabled: Bool) async throws -> NotificationSettingsFfi {
        guard let activeAccountRef else { throw NotificationSettingsActionError.noActiveAccount }
        return darkmatter_iosTests.notificationSettings(accountRef: activeAccountRef, nativePushEnabled: enabled)
    }

    func syncNativePushRegistration(accountRef: String) async throws -> PushRegistrationFfi {
        darkmatter_iosTests.pushRegistration(accountRef: accountRef)
    }

    func waitUntilSetLocalNotificationsStarted() async {
        guard !setLocalNotificationsStarted else { return }
        await withCheckedContinuation { continuation in
            setLocalNotificationsStartWaiters.append(continuation)
        }
    }

    func completeSetLocalNotifications(with settings: NotificationSettingsFfi) {
        setLocalNotificationsContinuation?.resume(returning: settings)
        setLocalNotificationsContinuation = nil
    }
}

private func notificationSettings(
    accountRef: String,
    localNotificationsEnabled: Bool = true,
    nativePushEnabled: Bool = false
) -> NotificationSettingsFfi {
    NotificationSettingsFfi(
        accountRef: accountRef,
        accountIdHex: "\(accountRef)-id",
        localNotificationsEnabled: localNotificationsEnabled,
        nativePushEnabled: nativePushEnabled
    )
}

private func pushRegistration(accountRef: String) -> PushRegistrationFfi {
    PushRegistrationFfi(
        accountRef: accountRef,
        accountIdHex: "\(accountRef)-id",
        platform: .apns,
        tokenFingerprint: "\(accountRef)-token",
        serverPubkeyHex: "server-pubkey",
        relayHint: nil,
        createdAtMs: 1,
        updatedAtMs: 2,
        lastSharedAtMs: nil
    )
}
