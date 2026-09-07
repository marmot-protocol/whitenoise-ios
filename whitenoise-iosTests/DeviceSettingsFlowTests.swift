import Darwin
import Foundation
import Testing
@testable import whitenoise_ios

@MainActor
struct DeviceSettingsFlowTests {
    @Test func diagnosticsPromptIsDeviceWideAndWaitsForEntryDismissal() throws {
        let name = "DiagnosticsConsentTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let consent = DeviceDiagnosticsConsent(defaults: defaults)
        #expect(!consent.canPresent(chatsVisible: true, anotherSheetVisible: false, runtimeReady: true))
        consent.scheduleAfterSignIn()
        #expect(DeviceDiagnosticsConsent(defaults: defaults).pending)
        consent.onboardingVisible = true
        #expect(!consent.canPresent(chatsVisible: true, anotherSheetVisible: false, runtimeReady: true))
        consent.onboardingVisible = false
        #expect(!consent.canPresent(chatsVisible: false, anotherSheetVisible: false, runtimeReady: true))
        #expect(!consent.canPresent(chatsVisible: true, anotherSheetVisible: true, runtimeReady: true))
        #expect(!consent.canPresent(chatsVisible: true, anotherSheetVisible: false, runtimeReady: false))
        #expect(!consent.canPresent(chatsVisible: true, anotherSheetVisible: false, runtimeReady: true,
                                   chatNavigationPending: true))
        #expect(consent.canPresent(chatsVisible: true, anotherSheetVisible: false, runtimeReady: true))
        consent.complete()
        let relaunched = DeviceDiagnosticsConsent(defaults: defaults)
        relaunched.scheduleAfterSignIn()
        #expect(!relaunched.pending)
        relaunched.reset()
        relaunched.scheduleAfterSignIn()
        #expect(relaunched.pending)
    }

    @Test func profileChooserSurvivesLaunchUntilAProfileIsSelected() throws {
        let name = "ProfileChooserTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let accounts = AccountStore(defaults: defaults)
        #expect(!accounts.prefersProfileSelection)
        accounts.activeAccountRef = "alice"
        accounts.requestProfileSelection()
        #expect(accounts.returnsToSettingsAfterSelection)
        let restored = AccountStore(defaults: defaults)
        #expect(!restored.returnsToSettingsAfterSelection)
        #expect(restored.activeAccountRef == nil)
        #expect(restored.prefersProfileSelection)
        restored.activeAccountRef = "bob"
        #expect(!AccountStore(defaults: defaults).prefersProfileSelection)
        accounts.activeAccountRef = "bob"
        #expect(!accounts.returnsToSettingsAfterSelection)
    }

    @Test func unfinishedErasureCanBeRetriedAfterRelaunch() throws {
        let name = "ErasureStateTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let state = AppDataErasureState(defaults: defaults)
        state.begin()
        #expect(AppDataErasureState(defaults: defaults).needsRecovery)
        state.failed()
        #expect(state.needsRecovery)
        state.complete()
        #expect(!AppDataErasureState(defaults: defaults).needsRecovery)
    }

    @Test func erasureJournalSurvivesRemovalOfAccountPreferences() async throws {
        let accountSuite = "ErasureAccounts.\(UUID())"
        let journalSuite = "ErasureJournal.\(UUID())"
        let accounts = try #require(UserDefaults(suiteName: accountSuite))
        let journal = try #require(UserDefaults(suiteName: journalSuite))
        defer {
            accounts.removePersistentDomain(forName: accountSuite)
            journal.removePersistentDomain(forName: journalSuite)
        }
        let appState = AppState(client: try MarmotClient.testClient(), notifications: .shared,
                                accountDefaults: accounts, erasureDefaults: journal)
        appState.erasureState.begin()
        accounts.removePersistentDomain(forName: accountSuite)
        let restored = AppDataErasureState(defaults: journal, legacyDefaults: accounts)
        #expect(restored.needsRecovery)
        restored.complete()
        #expect(!AppDataErasureState(defaults: journal, legacyDefaults: accounts).needsRecovery)
    }

    @Test func recoverySheetRemainsVisibleThroughoutRetryButNotOrdinaryErasure() throws {
        let suite = "ErasurePresentation.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppDataErasureState(defaults: defaults)
        state.begin()
        #expect(!state.shouldPresentRecovery(activeAccountRef: nil, runtimeReady: false))
        state.failed()
        #expect(state.shouldPresentRecovery(activeAccountRef: nil, runtimeReady: true))
        state.begin()
        #expect(!state.needsRecovery)
        #expect(state.shouldPresentRecovery(activeAccountRef: nil, runtimeReady: false))
        #expect(state.shouldPresentRecovery(activeAccountRef: "restored-during-bootstrap", runtimeReady: false))
        state.failed()
        #expect(state.shouldPresentRecovery(activeAccountRef: nil, runtimeReady: true))
        state.complete()
        #expect(!state.shouldPresentRecovery(activeAccountRef: nil, runtimeReady: true))
    }

    @Test func interruptedSignInRequiresExplicitCompletionAcrossLaunches() throws {
        let name = "SignInAttemptTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let attempt = SignInAttemptStore(defaults: defaults)
        attempt.begin("profile-a")
        let restored = SignInAttemptStore(defaults: defaults)
        #expect(restored.accountIDs.contains("profile-a"))
        restored.finish("profile-a")
        #expect(SignInAttemptStore(defaults: defaults).accountIDs.isEmpty)
    }

    @Test func destructiveProfileConfirmationIsExactAndBoundToTheDisplayedName() {
        #expect(ProfileExitConfirmation.canSignOut(wiping: true, input: "  Alice  ", profileName: "Alice", busy: false))
        #expect(!ProfileExitConfirmation.canSignOut(wiping: true, input: "alice", profileName: "Alice", busy: false))
        #expect(!ProfileExitConfirmation.canSignOut(wiping: true, input: "Alice", profileName: "Bob", busy: false))
        #expect(!ProfileExitConfirmation.canSignOut(wiping: true, input: "", profileName: "", busy: false))
        #expect(ProfileExitConfirmation.canSignOut(wiping: false, input: "", profileName: "Alice", busy: false))
        #expect(!ProfileExitConfirmation.canSignOut(wiping: false, input: "", profileName: "Alice", busy: true))
        #expect(!ProfileExitConfirmation.matches("apple  bird cloud", expected: "apple bird cloud"))
        #expect(ProfileExitConfirmation.erasePhrase().split(separator: " ").count == 3)
    }

    @Test func diagnosticSummaryExcludesPayloadsAndIdentifyingMetadata() throws {
        let row: [String: Any] = [
            "wall_time_ms": 1_700_000_000_000 as UInt64,
            "kind": ["type": "epoch_confirmed", "message": "PRIVATE", "epoch": 17],
            "account_ref": "secret-account", "context": ["source": ["device_name": "private device"]]
        ]
        let line = try #require(DiagnosticLogExport.summaryLine(JSONSerialization.data(withJSONObject: row)))
        #expect(line.contains("epoch_confirmed"))
        #expect(!line.contains("PRIVATE"))
        #expect(!line.contains("secret-account"))
        #expect(!line.contains("private device"))
        #expect(DiagnosticLogExport.summaryLine(Data("invalid".utf8)) == nil)
    }

    @Test func erasurePreservesLockInodeAndRefusesAConcurrentOwner() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let content = root.appendingPathComponent("shared.sqlite")
        try Data("private".utf8).write(to: content)
        let lock = root.appendingPathComponent(AppDataErasure.runtimeLockName)
        let descriptor = open(lock.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        #expect(descriptor >= 0)
        defer { close(descriptor) }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        var before = stat()
        #expect(fstat(descriptor, &before) == 0)
        #expect(throws: POSIXError.self) { try AppDataErasure.eraseClosedRuntime(at: root) }
        #expect(FileManager.default.fileExists(atPath: content.path))
        #expect(flock(descriptor, LOCK_UN) == 0)
        try AppDataErasure.eraseClosedRuntime(at: root)
        #expect(!FileManager.default.fileExists(atPath: content.path))
        var after = stat()
        #expect(lstat(lock.path, &after) == 0)
        #expect(before.st_ino == after.st_ino)
    }
}
