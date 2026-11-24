import Darwin
import Foundation
import MarmotKit
import Testing
@testable import whitenoise_ios

@MainActor
struct DeviceSettingsFlowTests {
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
        let appState = AppState.test(notifications: .shared,
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
        #expect(ProfileExitConfirmation.canSignOut(wiping: true, input: "Alice", profileName: "Alice", busy: false))
        #expect(!ProfileExitConfirmation.canSignOut(wiping: true, input: "  Alice  ", profileName: "Alice", busy: false))
        #expect(!ProfileExitConfirmation.canSignOut(wiping: true, input: "alice", profileName: "Alice", busy: false))
        #expect(!ProfileExitConfirmation.canSignOut(wiping: true, input: "Alice", profileName: "Bob", busy: false))
        #expect(!ProfileExitConfirmation.canSignOut(wiping: true, input: "", profileName: "", busy: false))
        #expect(ProfileExitConfirmation.canSignOut(wiping: false, input: "", profileName: "Alice", busy: false))
        #expect(!ProfileExitConfirmation.canSignOut(wiping: false, input: "", profileName: "Alice", busy: true))
        #expect(ProfileExitConfirmation.matches("  apple bird cloud  ", expected: "apple bird cloud"))
        #expect(!ProfileExitConfirmation.matches("apple  bird cloud", expected: "apple bird cloud"))
        #expect(ProfileExitConfirmation.erasePhrase().split(separator: " ").count == 3)
    }

    @Test func profileNameWhitespaceHintOnlyExplainsAnOtherwiseMatchingName() {
        for input in [" Alice", "Alice ", "\nAlice\t"] {
            #expect(ProfileExitConfirmation.hasExtraSurroundingWhitespace(input, profileName: "Alice"))
            #expect(!ProfileExitConfirmation.canSignOut(wiping: true, input: input, profileName: "Alice", busy: false))
        }
        for input in ["Alice", "", " ", "alice ", "Bob ", "Ali ce"] {
            #expect(!ProfileExitConfirmation.hasExtraSurroundingWhitespace(input, profileName: "Alice"))
        }
        #expect(!ProfileExitConfirmation.hasExtraSurroundingWhitespace(" ", profileName: ""))
        #expect(!ProfileExitConfirmation.hasExtraSurroundingWhitespace(" Alice ", profileName: " Alice "))
        #expect(ProfileExitConfirmation.canSignOut(wiping: true, input: " Alice ", profileName: " Alice ", busy: false))
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

    @Test func clearContainerFilesClearsAppGroupCachesWhilePreservingRuntimeLock() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClearContainerFilesTests-\(UUID().uuidString)", isDirectory: true)
        let appCaches = sandbox.appendingPathComponent("App/Library/Caches", isDirectory: true)
        let appSupport = sandbox.appendingPathComponent("App/Library/Application Support", isDirectory: true)
        let documents = sandbox.appendingPathComponent("App/Documents", isDirectory: true)
        let temp = sandbox.appendingPathComponent("App/tmp", isDirectory: true)
        let appGroup = sandbox.appendingPathComponent("AppGroup", isDirectory: true)
        let sharedAvatars = appGroup.appendingPathComponent("Library/Caches/NotificationAvatars", isDirectory: true)
        let marmotRoot = AppContainerConfig.marmotRoot(in: appGroup)
        for directory in [appCaches, appSupport, documents, temp, sharedAvatars, marmotRoot] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let appCacheFile = appCaches.appendingPathComponent("cached.bin")
        let supportFile = appSupport.appendingPathComponent("state.bin")
        let documentFile = documents.appendingPathComponent("export.json")
        let tempFile = temp.appendingPathComponent("scratch.tmp")
        let notificationAvatar = sharedAvatars.appendingPathComponent("sender-avatar")
        let runtimeLock = marmotRoot.appendingPathComponent(AppDataErasure.runtimeLockName)
        for file in [appCacheFile, supportFile, documentFile, tempFile, notificationAvatar, runtimeLock] {
            try Data("x".utf8).write(to: file)
        }
        var lockBefore = stat()
        #expect(lstat(runtimeLock.path, &lockBefore) == 0)

        let stub = ContainerCleanupStubFileManager(
            caches: appCaches,
            applicationSupport: appSupport,
            documents: documents,
            temp: temp,
            sharedContainer: appGroup
        )
        try AppDataErasure.clearContainerFiles(fileManager: stub)

        #expect(!FileManager.default.fileExists(atPath: appCacheFile.path))
        #expect(!FileManager.default.fileExists(atPath: supportFile.path))
        #expect(!FileManager.default.fileExists(atPath: documentFile.path))
        #expect(!FileManager.default.fileExists(atPath: tempFile.path))
        #expect(!FileManager.default.fileExists(atPath: sharedAvatars.path))
        #expect(FileManager.default.fileExists(atPath: runtimeLock.path))
        var lockAfter = stat()
        #expect(lstat(runtimeLock.path, &lockAfter) == 0)
        #expect(lockBefore.st_ino == lockAfter.st_ino)

        // Missing App Group container must throw so full erasure stays in recovery.
        let unavailableContainerStub = ContainerCleanupStubFileManager(
            caches: appCaches,
            applicationSupport: appSupport,
            documents: documents,
            temp: temp,
            sharedContainer: nil
        )
        #expect(throws: AppContainerError.appGroupContainerUnavailable) {
            try AppDataErasure.clearContainerFiles(fileManager: unavailableContainerStub)
        }

        // Enumeration failure (other than confirmed absence) must propagate.
        let permissionDeniedStub = ContainerCleanupStubFileManager(
            caches: appCaches,
            applicationSupport: appSupport,
            documents: documents,
            temp: temp,
            sharedContainer: appGroup,
            contentsError: CocoaError(.fileReadNoPermission)
        )
        #expect(throws: CocoaError.self) {
            try AppDataErasure.clearContainerFiles(fileManager: permissionDeniedStub)
        }
    }

    @Test func erasureInMemoryResetClearsRetainedStateWithoutRewritingUserDefaults() async throws {
        let suiteName = "ErasureInMemoryReset.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let checkpointStore = AppReviewDemoCheckpointStore(defaults: defaults)
        try checkpointStore.save(AppReviewDemoCheckpoint(
            originalAccountRef: "alice",
            originalAccountIdHex: hex("aa"),
            initialAccountRefs: ["alice"],
            groupIdHex: hex("11"),
            completed: true
        ))
        let appState = AppState.test(accountDefaults: defaults, preferenceDefaults: defaults)
        #expect(appState.appReviewDemo.hasSavedSetup)
        #expect(appState.appReviewDemo.status == .ready(groupIdHex: hex("11"), accountRef: "alice"))

        appState.noteDirectChatPeer(accountRef: "alice", groupIdHex: hex("11"), peerAccountIdHex: hex("bb"))
        appState.noteCreatedChatListRow(
            accountRef: "alice",
            row: chatListRow(groupIdHex: hex("11"), title: "Bob")
        )
        appState.deviceLinks.noteSetupFinished(accountIdHex: hex("aa"))
        appState.deviceLinks.dismissNewDeviceOffer()
        appState.deviceLinks.observe(.deviceUnlinked(accountIdHex: hex("aa"), accountLabel: "alice"), using: appState)
        appState.startupDiagnosticsEnabled = true
        #expect(defaults.object(forKey: StartupDiagnosticsPreference.key) != nil)

        // Cancel and clear the demo setup and reset preferences before wiping
        // persistent defaults, mirroring `eraseAppData()`, then wipe in-memory state.
        await appState.appReviewDemo.resetForErasure()
        appState.startupDiagnosticsEnabled = false
        defaults.removePersistentDomain(forName: suiteName)
        appState.resetInMemoryStateForErasure()

        #expect(appState.directChatPeerAccountId(accountRef: "alice", groupIdHex: hex("11")) == nil)
        #expect(appState.createdChatListRow(accountRef: "alice", groupIdHex: hex("11")) == nil)
        #expect(!appState.appReviewDemo.hasSavedSetup)
        #expect(appState.appReviewDemo.status == .idle)
        #expect(appState.deviceLinks.unlinkedNotice == nil)
        var unlinked = accountSummary("alice", byte: "aa", signedOut: true)
        unlinked.unlinked = true
        appState.deviceLinks.remindUnlinkedProfiles([unlinked])
        #expect(appState.deviceLinks.unlinkedNotice?.accountIdHex == hex("aa"))
        #expect(!appState.startupDiagnosticsEnabled)
        #expect(defaults.object(forKey: StartupDiagnosticsPreference.key) == nil)
    }
}

private final class ContainerCleanupStubFileManager: FileManager {
    private let caches: URL
    private let applicationSupport: URL
    private let documents: URL
    private let temp: URL
    private let sharedContainer: URL?
    private let contentsError: Error?

    init(
        caches: URL,
        applicationSupport: URL,
        documents: URL,
        temp: URL,
        sharedContainer: URL?,
        contentsError: Error? = nil
    ) {
        self.caches = caches
        self.applicationSupport = applicationSupport
        self.documents = documents
        self.temp = temp
        self.sharedContainer = sharedContainer
        self.contentsError = contentsError
        super.init()
    }

    override var temporaryDirectory: URL { temp }

    override func urls(
        for directory: FileManager.SearchPathDirectory,
        in domainMask: FileManager.SearchPathDomainMask
    ) -> [URL] {
        switch directory {
        case .cachesDirectory: [caches]
        case .applicationSupportDirectory: [applicationSupport]
        case .documentDirectory: [documents]
        default: super.urls(for: directory, in: domainMask)
        }
    }

    override func containerURL(forSecurityApplicationGroupIdentifier groupIdentifier: String) -> URL? {
        sharedContainer
    }

    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        if let contentsError { throw contentsError }
        return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }
}
