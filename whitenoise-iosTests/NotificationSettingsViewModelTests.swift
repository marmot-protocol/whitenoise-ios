import Foundation
import MarmotKit
import Testing
import UserNotifications
@testable import whitenoise_ios

/// Verifies the view model exposes the gate's state through `isSaving`, which the
/// view reads to disable controls while an action is in flight.
@MainActor
struct NotificationSettingsViewModelTests {
    @Test func isSavingDefaultsToFalse() {
        let model = NotificationSettingsViewModel()
        #expect(model.isSaving == false)
    }

    @Test func nativePushToggleUnavailableWhenSettingsMissing() {
        let model = NotificationSettingsViewModel()
        // No settings loaded yet -> the native push toggle stays disabled.
        #expect(model.nativePushToggleUnavailable == true)
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

    @Test func loadingEndsWhenSettingsAreUnavailableAndRetryCanLoadThem() async throws {
        let model = NotificationSettingsViewModel(previewDefaults: nil, mutedChatMentionsDefaults: nil)
        let dataSource = NotificationSettingsViewModelDataSourceStub(activeAccountRef: "account-a")
        let releaseAuthorization = TestLatch()
        dataSource.authorizationRelease = releaseAuthorization
        defer { releaseAuthorization.signal() }
        let reload = Task { await model.reload(using: dataSource) }
        try await dataSource.authorizationStarted.wait()

        #expect(model.isLoading)
        #expect(!model.hasLoadedAuthorization)
        releaseAuthorization.signal()
        await reload.value

        #expect(!model.isLoading)
        #expect(model.hasLoadedAuthorization)
        #expect(model.settings == nil)

        dataSource.settingsByAccount["account-a"] = notificationSettings(accountRef: "account-a")
        await model.reload(using: dataSource)
        #expect(!model.isLoading)
        #expect(model.settings == dataSource.settingsByAccount["account-a"])
    }

    @Test func initialLoadDeferredByAnActionStaysLoadingUntilReplayFinishes() async throws {
        let model = NotificationSettingsViewModel(previewDefaults: nil, mutedChatMentionsDefaults: nil)
        let dataSource = NotificationSettingsViewModelDataSourceStub(activeAccountRef: "account-a")
        let expectedSettings = notificationSettings(accountRef: "account-a")
        dataSource.settingsByAccount["account-a"] = expectedSettings
        let releaseSettings = TestLatch()
        dataSource.settingsRelease = releaseSettings
        defer {
            releaseSettings.signal()
            dataSource.completeSetLocalNotifications(with: expectedSettings)
        }
        let reload = Task { await model.reload(using: dataSource) }
        try await dataSource.settingsStarted.wait()
        #expect(model.hasLoadedAuthorization)

        let action = Task { await model.setLocalNotifications(true, using: dataSource) }
        try await dataSource.waitUntilSetLocalNotificationsStarted()
        releaseSettings.signal()
        await reload.value

        #expect(model.isSaving)
        #expect(model.settings == nil)
        #expect(model.isLoading)

        dataSource.completeSetLocalNotifications(with: expectedSettings)
        await action.value
        #expect(!model.isSaving)
        #expect(!model.isLoading)
        #expect(model.settings == expectedSettings)
    }

    @Test func refreshKeepsLoadedSettingsVisible() async throws {
        let model = NotificationSettingsViewModel(previewDefaults: nil, mutedChatMentionsDefaults: nil)
        let initialSource = NotificationSettingsViewModelDataSourceStub(activeAccountRef: "account-a")
        let loadedSettings = notificationSettings(accountRef: "account-a")
        initialSource.settingsByAccount["account-a"] = loadedSettings
        await model.reload(using: initialSource)

        let refreshSource = NotificationSettingsViewModelDataSourceStub(activeAccountRef: "account-a")
        refreshSource.settingsByAccount["account-a"] = loadedSettings
        let releaseAuthorization = TestLatch()
        refreshSource.authorizationRelease = releaseAuthorization
        defer { releaseAuthorization.signal() }
        let refresh = Task { await model.reload(using: refreshSource) }
        try await refreshSource.authorizationStarted.wait()

        #expect(!model.isLoading)
        #expect(model.settings == loadedSettings)
        releaseAuthorization.signal()
        await refresh.value
        #expect(!model.isLoading)
    }

    @Test func actionErrorSurvivesReloadAndOtherActionsUntilRetried() async throws {
        let model = NotificationSettingsViewModel(previewDefaults: nil, mutedChatMentionsDefaults: nil)
        let dataSource = NotificationSettingsViewModelDataSourceStub(activeAccountRef: "account-a")
        dataSource.nativePushError = NotificationSettingsActionError.permissionDenied
        await model.setNativePush(true, using: dataSource)
        let failure = try #require(model.actionErrors[.nativePush])

        await model.reload(using: dataSource)
        await model.syncNativeRegistration(using: dataSource)
        #expect(model.actionErrors[.nativePush] == failure)

        dataSource.nativePushError = nil
        await model.setNativePush(true, using: dataSource)
        #expect(model.actionErrors[.nativePush] == nil)
        #expect(model.settings?.nativePushEnabled == true)
    }

    @Test(arguments: [false, true])
    func successfulNativePushChangeClearsResolvedSetupError(enabled: Bool) async throws {
        let model = NotificationSettingsViewModel(previewDefaults: nil, mutedChatMentionsDefaults: nil)
        let dataSource = NotificationSettingsViewModelDataSourceStub(activeAccountRef: "account-a")
        dataSource.registrationError = NotificationSettingsActionError.permissionDenied
        await model.syncNativeRegistration(using: dataSource)
        #expect(model.actionErrors[.setup] != nil)

        dataSource.registrationError = nil
        dataSource.registrationsByAccount["account-a"] = pushRegistration(accountRef: "account-a")
        await model.setNativePush(enabled, using: dataSource)

        #expect(model.settings?.nativePushEnabled == enabled)
        #expect(model.actionErrors[.setup] == nil)
    }

    @Test func failedNativePushChangePreservesUnresolvedSetupError() async throws {
        let model = NotificationSettingsViewModel(previewDefaults: nil, mutedChatMentionsDefaults: nil)
        let dataSource = NotificationSettingsViewModelDataSourceStub(activeAccountRef: "account-a")
        dataSource.registrationError = NotificationSettingsActionError.permissionDenied
        await model.syncNativeRegistration(using: dataSource)
        let setupError = try #require(model.actionErrors[.setup])

        dataSource.nativePushError = NotificationSettingsActionError.permissionDenied
        await model.setNativePush(true, using: dataSource)

        #expect(model.actionErrors[.setup] == setupError)
        #expect(model.actionErrors[.nativePush] != nil)
    }

    @Test func actionErrorsDoNotFollowAnAccountSwitch() async {
        let model = NotificationSettingsViewModel(previewDefaults: nil, mutedChatMentionsDefaults: nil)
        let dataSource = NotificationSettingsViewModelDataSourceStub(activeAccountRef: "account-a")
        dataSource.nativePushError = NotificationSettingsActionError.permissionDenied
        await model.setNativePush(true, using: dataSource)
        #expect(model.actionErrors[.nativePush] != nil)

        dataSource.activeAccountRef = "account-b"
        await model.reload(using: dataSource)
        #expect(model.actionErrors.isEmpty)
    }

    @Test func accountSwitchDuringActionReplaysReloadInsteadOfPublishingOldAccountResult() async throws {
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
        try await dataSource.waitUntilSetLocalNotificationsStarted()

        dataSource.activeAccountRef = "account-b"
        await model.reload(using: dataSource)
        dataSource.completeSetLocalNotifications(
            with: notificationSettings(accountRef: "account-a", localNotificationsEnabled: true)
        )
        await actionTask.value

        #expect(model.settings == currentAccountSettings)
        #expect(model.registration == currentAccountRegistration)
    }
}

@MainActor
private final class NotificationSettingsViewModelDataSourceStub: NotificationSettingsViewModelDataSource {
    var activeAccountRef: String?
    var authorizationStatus: UNAuthorizationStatus = .authorized
    let authorizationStarted = TestLatch()
    var authorizationRelease: TestLatch?
    let settingsStarted = TestLatch()
    var settingsRelease: TestLatch?
    var nativePushError: Error?
    var registrationError: Error?
    var settingsByAccount: [String: NotificationSettingsFfi] = [:]
    var registrationsByAccount: [String: PushRegistrationFfi] = [:]

    private let setLocalNotificationsStarted = TestLatch()
    private var setLocalNotificationsContinuation: CheckedContinuation<NotificationSettingsFfi, Error>?

    init(activeAccountRef: String?) {
        self.activeAccountRef = activeAccountRef
    }

    func notificationAuthorizationStatus() async -> UNAuthorizationStatus {
        authorizationStarted.signal()
        if let authorizationRelease { await authorizationRelease.hold() }
        return authorizationStatus
    }

    func requestNotificationAuthorizationAndRegister() async throws -> Bool {
        true
    }

    func refreshNotificationApnsToken() async throws -> String {
        "apns-token"
    }

    func notificationSettings(for accountRef: String) async -> NotificationSettingsFfi? {
        settingsStarted.signal()
        if let settingsRelease { await settingsRelease.hold() }
        return settingsByAccount[accountRef]
    }

    func pushRegistration(for accountRef: String) async -> PushRegistrationFfi? {
        registrationsByAccount[accountRef]
    }

    func setLocalNotificationsEnabled(_ _: Bool) async throws -> NotificationSettingsFfi {
        setLocalNotificationsStarted.signal()
        return try await withCheckedThrowingContinuation { continuation in
            setLocalNotificationsContinuation = continuation
        }
    }

    func setNativePushEnabled(_ enabled: Bool) async throws -> NotificationSettingsFfi {
        if let nativePushError { throw nativePushError }
        guard let activeAccountRef else { throw NotificationSettingsActionError.noActiveAccount }
        return whitenoise_iosTests.notificationSettings(accountRef: activeAccountRef, nativePushEnabled: enabled)
    }

    func syncNativePushRegistration(accountRef: String) async throws -> PushRegistrationFfi {
        if let registrationError { throw registrationError }
        return whitenoise_iosTests.pushRegistration(accountRef: accountRef)
    }

    func waitUntilSetLocalNotificationsStarted() async throws {
        try await setLocalNotificationsStarted.wait()
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
