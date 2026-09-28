import MarmotKit
import Testing
import UIKit

@testable import whitenoise_ios

@MainActor
struct CreateIdentityOnboardingTests {
    @Test func onlySignInPrefersTheCompactSheetHeight() {
        #expect(!OnboardingSheetContent.welcome.prefersCompactHeight)
        #expect(OnboardingSheetContent.signIn.prefersCompactHeight)
        #expect(!OnboardingSheetContent.signUp.prefersCompactHeight)
    }

    @Test func openingAndReopeningSignUpNeverCreatesAnAccount() async {
        let service = CreateIdentityServiceStub()
        for _ in 0..<2 {
            let model = CreateIdentityViewModel()
            await model.prepare(using: service)
            await model.prepare(using: service)
            #expect(model.displayName == "Suggested Name")
            #expect(model.phase == .editing)
            #expect(model.allowsBackNavigation)
            #expect(model.createdIdentity == nil)
        }
        #expect(service.suggestionCount == 2)
        #expect(service.createCount == 0)
        #expect(service.publishCount == 0)
        #expect(service.completeCount == 0)
    }

    @Test func submitPublishesTheDisplayedSuggestionInsteadOfTheCreationDefault() async {
        let service = CreateIdentityServiceStub()
        let model = CreateIdentityViewModel()
        await model.prepare(using: service)
        var dismissed = false
        await model.submit(using: service) { dismissed = true }
        #expect(service.createCount == 1)
        #expect(service.publishedProfile?.name == "Suggested Name")
        #expect(service.publishedProfile?.displayName == "Suggested Name")
        #expect(service.completeCount == 1)
        #expect(dismissed)
    }

    @Test func lateSuggestionDoesNotOverwriteTyping() async {
        let gate = IdentityCreationGate()
        let service = CreateIdentityServiceStub()
        service.beforeSuggestionReturn = { await gate.waitForRelease() }
        let model = CreateIdentityViewModel()
        let preparation = Task { await model.prepare(using: service) }
        await gate.waitUntilEntered()
        model.displayName = "Alice"
        await gate.release()
        await preparation.value
        #expect(model.displayName == "Alice")
        #expect(service.createCount == 0)
    }

    @Test func cancelledPreparationCannotChangeDraftOrCreateAccount() async {
        let gate = IdentityCreationGate()
        let service = CreateIdentityServiceStub()
        service.beforeSuggestionReturn = { await gate.waitForRelease() }
        let model = CreateIdentityViewModel()
        let preparation = Task { await model.prepare(using: service) }
        await gate.waitUntilEntered()
        preparation.cancel()
        await gate.release()
        await preparation.value
        #expect(model.displayName.isEmpty)
        #expect(service.createCount == 0)
        #expect(model.allowsBackNavigation)
    }

    @Test func emptyNameCannotCreateAccount() async {
        let service = CreateIdentityServiceStub()
        let model = CreateIdentityViewModel()
        model.displayName = " \n "
        await model.submit(using: service) {}
        #expect(service.createCount == 0)
        #expect(model.phase == .editing)
    }

    @Test func repeatedSubmissionDuringCreationDoesNotCreateOrCompleteTwice() async {
        let gate = IdentityCreationGate()
        let service = CreateIdentityServiceStub()
        service.beforeCreateReturn = { await gate.waitForRelease() }
        let model = CreateIdentityViewModel()
        model.displayName = "Alice"
        model.setAvatarDraft(Self.avatarDraft)
        let submission = Task { await model.submit(using: service) {} }
        await gate.waitUntilEntered()
        #expect(model.phase == .creating)
        #expect(!model.allowsBackNavigation)
        model.setAvatarDraft(nil)
        #expect(model.avatarDraft == Self.avatarDraft)
        await model.submit(using: service) {}
        #expect(service.createCount == 1)
        await gate.release()
        await submission.value
        #expect(service.completeCount == 1)
    }

    @Test func metadataMergePreservesUneditedFieldsAndSynchronizesEditedName() throws {
        let existing = UserProfileMetadataFfi(
            name: "engine-name",
            displayName: "Engine Name",
            about: "Engine about",
            picture: "https://example.com/old.jpg",
            banner: "https://example.com/banner.jpg",
            nip05: "engine@example.com",
            lud16: "engine@example.com"
        )
        let blank = OnboardingProfileMetadataDraft(
            displayName: " ",
            about: "",
            uploadedPictureURL: nil
        )
        #expect(blank.merging(with: existing) == nil)

        let edited = OnboardingProfileMetadataDraft(
            displayName: " Alice ",
            about: "Hello",
            uploadedPictureURL: "https://example.com/new.jpg"
        )
        let merged = try #require(edited.merging(with: existing))

        #expect(merged.name == "Alice")
        #expect(merged.displayName == "Alice")
        #expect(merged.about == "Hello")
        #expect(merged.picture == "https://example.com/new.jpg")
        #expect(merged.banner == existing.banner)
        #expect(merged.nip05 == existing.nip05)
        #expect(merged.lud16 == existing.lud16)
    }

    @Test func profileRetryNeverCreatesASecondIdentityOrUploadsAgain() async {
        let service = CreateIdentityServiceStub()
        service.publishFailuresRemaining = 1
        let model = CreateIdentityViewModel()
        model.displayName = "Alice"
        model.setAvatarDraft(Self.avatarDraft)
        var dismissCount = 0

        await model.submit(using: service) {
            dismissCount += 1
        }

        #expect(model.phase == .profileSaveFailed)
        #expect(model.avatarDraft == Self.avatarDraft)
        #expect(service.createCount == 1)
        #expect(service.uploadCount == 1)
        #expect(service.publishCount == 1)
        #expect(service.completeCount == 0)
        #expect(dismissCount == 0)

        await model.submit(using: service) {
            dismissCount += 1
        }

        #expect(service.createCount == 1)
        #expect(service.uploadCount == 1)
        #expect(service.publishCount == 2)
        #expect(service.completeCount == 1)
        #expect(dismissCount == 1)
    }

    @Test func creationFailureKeepsDraftAndAllowsARealCreationRetry() async {
        let service = CreateIdentityServiceStub()
        service.createFailuresRemaining = 1
        let model = CreateIdentityViewModel()
        model.displayName = "Alice"
        model.about = "Still here"
        model.setAvatarDraft(Self.avatarDraft)

        await model.submit(using: service) {}

        #expect(model.phase == .creationFailed)
        #expect(model.displayName == "Alice")
        #expect(model.about == "Still here")
        #expect(model.avatarDraft == Self.avatarDraft)
        #expect(service.createCount == 1)
        #expect(service.completeCount == 0)

        await model.submit(using: service) {}

        #expect(service.createCount == 2)
        #expect(service.completeCount == 1)
    }

    @Test func submitWaitsForNetworkSetupBeforeUploadingOrPublishing() async {
        let gate = IdentityCreationGate()
        let service = CreateIdentityServiceStub()
        service.beforeReadinessReturn = { await gate.waitForRelease() }
        let model = CreateIdentityViewModel()
        model.displayName = "Alice"
        model.setAvatarDraft(Self.avatarDraft)
        let submission = Task { await model.submit(using: service) {} }
        await gate.waitUntilEntered()
        #expect(model.phase == .finishingSetup)
        #expect(model.isSubmitting)
        #expect(service.uploadCount == 0)
        #expect(service.publishCount == 0)
        #expect(service.completeCount == 0)
        await model.submit(using: service) {}
        #expect(service.createCount == 1)
        await gate.release()
        await submission.value
        #expect(service.uploadCount == 1)
        #expect(service.publishCount == 1)
        #expect(service.completeCount == 1)
    }

    @Test func setupTimeoutPreservesDraftAndRetryResumesTheSameIdentity() async {
        let service = CreateIdentityServiceStub()
        service.readinessFailuresRemaining = 1
        let model = CreateIdentityViewModel()
        model.displayName = "Alice"
        model.about = "Hello"
        model.setAvatarDraft(Self.avatarDraft)
        var dismissCount = 0
        await model.submit(using: service) { dismissCount += 1 }
        #expect(model.phase == .setupFailed)
        #expect(!model.isBusy)
        #expect(model.displayName == "Alice")
        #expect(model.about == "Hello")
        #expect(model.avatarDraft == Self.avatarDraft)
        #expect(service.uploadCount == 0)
        #expect(service.publishCount == 0)
        #expect(service.completeCount == 0)
        #expect(dismissCount == 0)
        await model.submit(using: service) { dismissCount += 1 }
        #expect(service.createCount == 1)
        #expect(service.readinessRequests.map(\.accountRef) == [service.identity.label, service.identity.label])
        #expect(service.readinessRequests.map(\.retry) == [false, true])
        #expect(service.completeCount == 1)
        #expect(dismissCount == 1)
    }

    @Test func cancellationDuringAccountReadDoesNotCreateAnIdentity() async {
        let gate = IdentityCreationGate()
        let service = CreateIdentityServiceStub()
        service.beforeAccountsReturn = { await gate.waitForRelease() }
        let model = CreateIdentityViewModel()
        model.displayName = "Alice"
        let submission = Task { await model.submit(using: service) {} }
        await gate.waitUntilEntered()
        submission.cancel()
        await gate.release()
        await submission.value
        #expect(service.createCount == 0)
        #expect(service.uploadCount == 0)
        #expect(service.publishCount == 0)
        #expect(service.completeCount == 0)
        #expect(!model.isBusy)
        service.beforeAccountsReturn = nil
        await model.submit(using: service) {}
        #expect(service.createCount == 1)
        #expect(service.completeCount == 1)
    }

    @Test func cancellationDuringSetupDoesNotSaveOrActivateAndCanRetry() async {
        let gate = IdentityCreationGate()
        let service = CreateIdentityServiceStub()
        service.beforeReadinessReturn = { await gate.waitForRelease() }
        let model = CreateIdentityViewModel()
        model.displayName = "Alice"
        let submission = Task { await model.submit(using: service) {} }
        await gate.waitUntilEntered()
        submission.cancel()
        await gate.release()
        await submission.value
        #expect(model.phase == .editing)
        #expect(model.failure == nil)
        #expect(model.allowsBackNavigation)
        #expect(!model.isBusy)
        #expect(service.publishCount == 0)
        #expect(service.completeCount == 0)
        service.beforeReadinessReturn = nil
        await model.submit(using: service) {}
        #expect(service.createCount == 1)
        #expect(service.completeCount == 1)
    }

    @Test func failedUploadCanBeRemovedBeforeRetryWithoutCreatingAnotherAccount() async throws {
        let service = CreateIdentityServiceStub()
        service.uploadFailuresRemaining = 1
        let model = CreateIdentityViewModel()
        model.displayName = "Alice"
        model.setAvatarDraft(Self.avatarDraft)
        await model.submit(using: service) {}
        #expect(model.phase == .profileSaveFailed)
        #expect(service.completeCount == 0)
        #expect(service.publishCount == 0)
        try await model.acceptPreparedAvatar(nil)
        #expect(model.failure == nil)
        await model.submit(using: service) {}
        #expect(service.createCount == 1)
        #expect(service.uploadCount == 1)
        #expect(service.publishedProfile?.picture == nil)
        #expect(service.completeCount == 1)
    }

    @Test func uploadFailurePreservesPhotoAndRetryReusesTheAccount() async {
        let service = CreateIdentityServiceStub()
        service.uploadFailuresRemaining = 2
        let model = CreateIdentityViewModel()
        model.displayName = "Alice"
        model.about = "Hello"
        model.setAvatarDraft(Self.avatarDraft)
        for _ in 0..<2 {
            await model.submit(using: service) {}
            #expect(model.failure == .photoUpload)
            #expect(model.avatarDraft == Self.avatarDraft)
            #expect(model.displayName == "Alice")
            #expect(model.about == "Hello")
            #expect(!model.isBusy)
            #expect(service.createCount == 1)
            #expect(service.publishCount == 0)
            #expect(service.completeCount == 0)
        }
        await model.submit(using: service) {}
        #expect(model.failure == nil)
        #expect(service.createCount == 1)
        #expect(service.uploadCount == 3)
        #expect(service.publishedProfile?.picture == "https://example.com/avatar.jpg")
        #expect(service.completeCount == 1)
    }

    @Test func readinessWaiterRequiresNetworkReady() async throws {
        var states: [AccountSetupReadinessFfi] = [.initializing, .localReady, .publishing, .networkReady]
        try await IdentitySetupReadinessWaiter.wait {
            states.removeFirst()
        }
        #expect(states.isEmpty)
    }

    @Test func readinessWaiterStopsOnTimeoutRecoveryAndCancellation() async {
        await #expect(throws: IdentitySetupReadinessWaiter.Failure.timedOut) {
            try await IdentitySetupReadinessWaiter.wait(timeout: .zero) { .publishing }
        }
        await #expect(throws: IdentitySetupReadinessWaiter.Failure.recoveryRequired) {
            try await IdentitySetupReadinessWaiter.wait { .recoveryRequired }
        }
        let gate = IdentityCreationGate()
        let waiting = Task {
            try await IdentitySetupReadinessWaiter.wait {
                await gate.waitForRelease()
                return .networkReady
            }
        }
        await gate.waitUntilEntered()
        waiting.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) { try await waiting.value }
    }

    @Test func unsubmittedFormStaysInMemoryUntilClosedThenReopensFresh() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SignUpDraftStore(directory: directory)
        let appState = AppState.test(client: nil, notifications: .shared, signUpDraftStore: store)
        await appState.openSignUpDraft()
        let model = appState.signUpModel
        model.displayName = "Alice"
        model.about = "Hello"
        try await model.acceptPreparedAvatar(Self.avatarDraft)
        await model.persistDraft()
        #expect(model.displayName == "Alice")
        #expect(model.about == "Hello")
        #expect(model.avatarDraft == Self.avatarDraft)
        #expect(try await store.load() == nil)

        appState.closeSignUpDraft()
        await appState.openSignUpDraft()
        #expect(appState.signUpModel !== model)
        #expect(appState.signUpModel.displayName.isEmpty)
        #expect(appState.signUpModel.about.isEmpty)
        #expect(appState.signUpModel.avatarDraft == nil)
        #expect(try await store.load() == nil)
    }

    @Test func closingAfterFailedSubmissionKeepsRecoveryEvenWithoutAnAccount() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SignUpDraftStore(directory: directory)
        let appState = AppState.test(client: nil, notifications: .shared, signUpDraftStore: store)
        await appState.openSignUpDraft()
        let model = appState.signUpModel
        model.displayName = "Alice"
        model.setAvatarDraft(Self.avatarDraft)
        let service = CreateIdentityServiceStub()
        service.createFailuresRemaining = 1
        await model.submit(using: service) {}
        #expect(model.failure == .creation)
        #expect(model.createdIdentity == nil)
        appState.closeSignUpDraft()
        await appState.openSignUpDraft()
        #expect(appState.signUpModel === model)
        let saved = try #require(try await SignUpDraftStore(directory: directory).load())
        #expect(saved.displayName == "Alice")
        #expect(saved.photo?.data == Self.avatarDraft.data)
        #expect(saved.stage == .creating)
    }

    @Test func failedRestartKeepsProgressAndRetryRemovesOnlyTheUnfinishedAccount() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SignUpDraftStore(directory: directory)
        let service = CreateIdentityServiceStub()
        let existing = AccountSummaryFfi(label: "existing", accountIdHex: "existing", localSigning: true,
                                         externalSigning: false, signedOut: false, running: true)
        service.storedAccounts = [existing]
        service.publishFailuresRemaining = 1
        let model = CreateIdentityViewModel()
        await model.configurePersistence(store: store)
        model.displayName = "Alice"
        model.about = "Hello"
        model.setAvatarDraft(Self.avatarDraft)
        await model.submit(using: service) {}
        service.removeFailuresRemaining = 1
        #expect(await model.startOver(using: service) == false)
        #expect(model.failure == .restart)
        #expect(model.displayName == "Alice")
        #expect(model.avatarDraft == Self.avatarDraft)
        #expect(try await store.load()?.stage == .resetting)
        await model.submit(using: service) {}
        #expect(service.createCount == 1)
        #expect(service.completeCount == 0)

        #expect(await model.startOver(using: service))
        #expect(service.storedAccounts == [existing])
        #expect(model.displayName.isEmpty)
        #expect(model.about.isEmpty)
        #expect(model.avatarDraft == nil)
        #expect(!model.isResetPending)
        #expect(model.createdIdentity == nil)
        #expect(try await store.load() == nil)
    }

    @Test func interruptedRestartCanFinishAfterAccountRemovalWithoutDeletingAnotherAccount() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SignUpDraftStore(directory: directory)
        let service = CreateIdentityServiceStub()
        service.publishFailuresRemaining = 1
        let model = CreateIdentityViewModel()
        await model.configurePersistence(store: store)
        model.displayName = "Alice"
        await model.submit(using: service) {}
        service.loseRemovalReply = true
        #expect(await model.startOver(using: service) == false)
        let saved = try #require(try await store.load())
        #expect(saved.stage == .resetting)
        let unrelated = AccountSummaryFfi(label: "unrelated", accountIdHex: "unrelated", localSigning: true,
                                          externalSigning: false, signedOut: false, running: true)
        service.storedAccounts = [unrelated]
        #expect(try saved.recoveredAccount(in: service.storedAccounts) == nil)
        let restored = CreateIdentityViewModel()
        await restored.configurePersistence(store: store, restored: saved)
        await restored.prepare(using: service)
        #expect(!restored.isResetPending)
        #expect(restored.failure == nil)
        #expect(restored.phase == .editing)
        #expect(restored.displayName == "Suggested Name")
        #expect(restored.about.isEmpty)
        #expect(restored.avatarDraft == nil)
        #expect(service.createCount == 1)
        #expect(service.removeCount == 1)
        #expect(service.storedAccounts == [unrelated])
        #expect(try await store.load() == nil)
    }

    @Test func relaunchAfterUploadReusesAccountAndUploadedPhoto() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = CreateIdentityServiceStub()
        service.publishFailuresRemaining = 1
        let first = CreateIdentityViewModel()
        await first.configurePersistence(store: SignUpDraftStore(directory: directory))
        first.displayName = "Alice"
        first.about = "Hello"
        first.setAvatarDraft(Self.avatarDraft)
        await first.submit(using: service) {}
        #expect(first.failure == .profile)
        let store = SignUpDraftStore(directory: directory)
        let saved = try #require(try await store.load())
        #expect(saved.stage == .publishing)
        #expect(saved.uploadedPhotoURL == "https://example.com/avatar.jpg")
        let restored = CreateIdentityViewModel()
        await restored.configurePersistence(store: store, restored: saved, identity: service.identity)
        #expect(restored.displayName == "Alice")
        #expect(restored.about == "Hello")
        #expect(restored.avatarDraft == Self.avatarDraft)
        #expect(restored.phase == .editing)
        #expect(restored.failure == nil)
        #expect(restored.allowsBackNavigation)
        await restored.prepare(using: service)
        #expect(service.completeCount == 0)
        #expect(restored.displayName == "Alice")
        await restored.submit(using: service) {}
        #expect(service.createCount == 1)
        #expect(service.uploadCount == 1)
        #expect(service.completeCount == 1)
        #expect(try await store.load() == nil)
    }

    @Test func restoredResetFailureNeedsExplicitRetryBeforeAnotherSignUp() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SignUpDraftStore(directory: directory)
        let service = CreateIdentityServiceStub()
        service.storedAccounts = [service.identity]
        service.removeFailuresRemaining = 1
        var draft = SignUpDraft()
        draft.stage = .resetting
        draft.displayName = "Alice"
        draft.accountID = service.identity.accountIdHex
        draft.accountRef = service.identity.label
        try await store.save(draft)
        let model = CreateIdentityViewModel()
        await model.configurePersistence(store: store, restored: draft, identity: service.identity)

        await model.prepare(using: service)
        #expect(model.failure == .restart)
        #expect(model.isResetPending)
        #expect(try await store.load()?.stage == .resetting)
        await model.prepare(using: service)
        await model.submit(using: service) {}
        #expect(service.removeCount == 1)
        #expect(service.createCount == 0)
        #expect(service.completeCount == 0)

        #expect(await model.startOver(using: service))
        #expect(service.storedAccounts.isEmpty)
        #expect(model.displayName.isEmpty)
        #expect(model.failure == nil)
        #expect(!model.isResetPending)
        #expect(try await store.load() == nil)
    }

    @Test func lostCreationResponseCannotPublishOrDeleteAnUnidentifiedAccount() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = CreateIdentityServiceStub()
        service.loseCreationReply = true
        let model = CreateIdentityViewModel()
        await model.configurePersistence(store: SignUpDraftStore(directory: directory))
        model.displayName = "Alice"
        await model.submit(using: service) {}
        #expect(model.failure == .creation)
        await model.submit(using: service) {}
        #expect(model.isRestorationBlocked)
        #expect(service.createCount == 1)
        #expect(service.publishCount == 0)
        #expect(service.completeCount == 0)
        #expect(await model.startOver(using: service) == false)
        #expect(service.removeCount == 0)
        #expect(await model.discardUnrestorableDraft())
        #expect(service.storedAccounts == [service.identity])
        #expect(try await SignUpDraftStore(directory: directory).load() == nil)
    }

    @Test func startOverCannotAdoptAnAccountImportedAfterFailedCreation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = CreateIdentityServiceStub()
        service.createFailuresRemaining = 1
        let model = CreateIdentityViewModel()
        await model.configurePersistence(store: SignUpDraftStore(directory: directory))
        model.displayName = "Alice"
        await model.submit(using: service) {}
        service.storedAccounts = [service.identity]
        #expect(await model.startOver(using: service) == false)
        #expect(model.isRestorationBlocked)
        #expect(service.removeCount == 0)
        #expect(service.storedAccounts == [service.identity])
        #expect(await model.discardUnrestorableDraft())
        #expect(service.storedAccounts == [service.identity])
    }

    @Test func unreadableDraftDoesNotAbortAccountRefreshAndCanBeDiscarded() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("draft.json")
        let invalid = Data("broken".utf8)
        try invalid.write(to: file)
        let client = try MarmotClient.testClient()
        try await client.startRuntime()
        let state = AppState.test(client: client, notifications: .shared,
                             signUpDraftStore: SignUpDraftStore(directory: directory))
        try await state.refreshAccounts(refreshUnreadSummaries: false)
        #expect(state.hasRestoredSignUp)
        #expect(state.restoreSignUpPresentation)
        #expect(state.signUpModel.isRestorationBlocked)
        try await state.refreshAccounts(refreshUnreadSummaries: false)
        await state.signUpModel.persistDraft()
        #expect(try Data(contentsOf: file) == invalid)
        let blocked = state.signUpModel
        state.closeSignUpDraft()
        #expect(state.signUpModel === blocked)
        #expect(await state.signUpModel.discardUnrestorableDraft())
        #expect(!FileManager.default.fileExists(atPath: file.path))
        try await client.marmot.shutdownAndClose()
    }

    @Test(arguments: [false, true])
    func missingOrUnidentifiedAccountOffersRecoveryWithoutChangingAccounts(unknownID: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SignUpDraftStore(directory: directory)
        var draft = SignUpDraft()
        draft.stage = .creating
        draft.baselineAccountIDs = []
        draft.accountID = unknownID ? nil : "missing"
        try await store.save(draft)
        let client = try MarmotClient.testClient()
        let state = AppState.test(client: client, notifications: .shared, signUpDraftStore: store)
        let unrelated = CreateIdentityServiceStub().identity
        try await state.restoreSignUpIfNeeded(accounts: [unrelated], client: client)
        #expect(state.hasRestoredSignUp)
        #expect(state.restoreSignUpPresentation)
        #expect(state.signUpModel.isRestorationBlocked)
        #expect(!state.isUnfinishedSignUpAccount(unrelated.accountIdHex))
        await state.signUpModel.persistDraft()
        #expect(try await store.load() == draft)
        #expect(await state.signUpModel.discardUnrestorableDraft())
        #expect(try await store.load() == nil)
    }

    @Test func restorationReadFailureBlocksOnlyTheRecordedSignUpAccount() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SignUpDraftStore(directory: directory)
        let identity = CreateIdentityServiceStub().identity
        var draft = SignUpDraft()
        draft.stage = .setup
        draft.accountID = identity.accountIdHex
        draft.accountRef = identity.label
        try await store.save(draft)
        let client = try MarmotClient.testClient()
        let state = AppState.test(client: client, notifications: .shared, signUpDraftStore: store)
        try await client.startRuntime()
        // The stale account list names an identity absent from this runtime's store.
        await #expect(throws: (any Error).self) {
            try await client.accountSetupReadiness(accountRef: identity.label)
        }

        try await state.restoreSignUpIfNeeded(accounts: [identity], client: client)

        #expect(state.hasRestoredSignUp)
        #expect(state.restoreSignUpPresentation)
        #expect(state.signUpModel.isRestorationBlocked)
        #expect(state.isUnfinishedSignUpAccount(identity.accountIdHex))
        #expect(!state.isUnfinishedSignUpAccount("unrelated"))
        await state.signUpModel.persistDraft()
        #expect(try await store.load() == draft)
        try await client.marmot.shutdownAndClose()
    }

    @Test func restorationFromAReplacedRuntimePreservesTheDraftForRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SignUpDraftStore(directory: directory)
        var draft = SignUpDraft()
        draft.stage = .setup
        try await store.save(draft)
        let previousClient = try MarmotClient.testClient()
        let state = AppState.test(client: try MarmotClient.testClient(), signUpDraftStore: store)

        await #expect(throws: CancellationError.self) {
            try await state.restoreSignUpIfNeeded(accounts: [], client: previousClient)
        }
        #expect(!state.hasRestoredSignUp)
        #expect(!state.restoreSignUpPresentation)
        #expect(!state.signUpModel.isRestorationBlocked)
        #expect(try await store.load() == draft)
    }

    @Test func pendingTextEditsFlushTogetherAndPreserveThePhoto() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SignUpDraftStore(directory: directory)
        var draft = SignUpDraft()
        draft.stage = .setup
        draft.displayName = "Alice"
        draft.photo = .init(data: Self.avatarDraft.data, mediaType: Self.avatarDraft.mediaType,
                            dim: Self.avatarDraft.dim, thumbhash: Self.avatarDraft.thumbhash)
        try await store.save(draft)
        let model = CreateIdentityViewModel()
        await model.configurePersistence(store: store, restored: draft)
        for name in ["B", "Bo", "Bob"] {
            model.displayName = name
            model.scheduleDraftPersistence(delay: .seconds(60))
        }
        model.about = "Updated bio"
        model.scheduleDraftPersistence(delay: .seconds(60))
        #expect(try await store.load() == draft)

        await model.persistDraft()

        let saved = try #require(try await store.load())
        #expect(saved.displayName == "Bob")
        #expect(saved.about == "Updated bio")
        #expect(saved.photo == draft.photo)
    }

    @Test func scheduledTextEditsPersistWithoutClosingTheForm() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SignUpDraftStore(directory: directory)
        var draft = SignUpDraft()
        draft.stage = .setup
        draft.displayName = "Alice"
        try await store.save(draft)
        let model = CreateIdentityViewModel()
        await model.configurePersistence(store: store, restored: draft)
        model.displayName = "Bob"
        // The view normally owns the model while its weakly captured save runs.
        defer { withExtendedLifetime(model) {} }
        let save = try #require(model.scheduleDraftPersistence(delay: .zero))
        await save.value

        #expect(try await store.load()?.displayName == "Bob")
    }

    @Test func editingRestoredCompletionPublishesTheNewValuesBeforeOpeningChats() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = CreateIdentityServiceStub()
        var draft = SignUpDraft()
        draft.stage = .completed
        draft.displayName = "Alice"
        draft.about = "Old bio"
        draft.uploadedPhotoURL = "https://example.com/old.jpg"
        draft.accountID = service.identity.accountIdHex
        draft.accountRef = service.identity.label
        let oldProfile = UserProfileMetadataFfi(name: "Alice", displayName: "Alice", about: "Old bio",
                                               picture: draft.uploadedPhotoURL, banner: nil, nip05: nil, lud16: nil)
        let model = CreateIdentityViewModel()
        await model.configurePersistence(store: SignUpDraftStore(directory: directory), restored: draft,
                                         identity: service.identity, profile: oldProfile)
        model.displayName = "New name"
        model.about = ""
        model.setAvatarDraft(nil)
        await model.submit(using: service) {}
        #expect(service.createCount == 0)
        #expect(service.publishCount == 1)
        #expect(service.publishedProfile?.name == "New name")
        #expect(service.publishedProfile?.about == nil)
        #expect(service.publishedProfile?.picture == nil)
        #expect(service.completeCount == 1)
    }

    @Test(arguments: [false, true])
    func failedPhotoChangePreservesAcceptedPhotoAndCheckpoint(removing: Bool) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([0]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let model = CreateIdentityViewModel()
        var submitted = SignUpDraft()
        submitted.stage = .publishing
        submitted.accountID = CreateIdentityServiceStub().identity.accountIdHex
        submitted.displayName = "Alice"
        submitted.photo = .init(data: Self.avatarDraft.data, mediaType: Self.avatarDraft.mediaType,
                                dim: Self.avatarDraft.dim, thumbhash: nil)
        submitted.uploadedPhotoURL = "https://example.com/accepted.jpg"
        await model.configurePersistence(store: SignUpDraftStore(directory: file), restored: submitted)
        let accepted = model.avatarDraft
        let replacement = GroupImageUploadDraft(data: Data([4, 5, 6]), mediaType: "image/jpeg",
                                                sourceURL: nil, dim: "1x1", thumbhash: nil)

        await #expect(throws: CocoaError(.fileWriteUnknown)) {
            try await model.acceptPreparedAvatar(removing ? nil : replacement)
        }
        #expect(model.avatarDraft == accepted)
        #expect(model.draft == submitted)
        #expect(!model.isBusy)
        #expect(model.allowsBackNavigation)
    }

    @Test func acceptedPhotoChangesSurviveRestorationAndInvalidateOldUploads() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SignUpDraftStore(directory: directory)
        var submitted = SignUpDraft()
        submitted.stage = .publishing
        submitted.accountID = CreateIdentityServiceStub().identity.accountIdHex
        submitted.uploadedPhotoURL = "https://example.com/old.jpg"
        let model = CreateIdentityViewModel()
        await model.configurePersistence(store: store, restored: submitted)

        try await model.acceptPreparedAvatar(Self.avatarDraft)
        let saved = try #require(try await store.load())
        #expect(saved.photo?.data == Self.avatarDraft.data)
        #expect(saved.uploadedPhotoURL == nil)
        #expect(saved.stage != .publishing)
        let restored = CreateIdentityViewModel()
        await restored.configurePersistence(store: store, restored: saved)
        #expect(restored.avatarDraft?.data == Self.avatarDraft.data)
        try await restored.acceptPreparedAvatar(nil)
        let removed = try #require(try await store.load())
        #expect(removed.photo == nil)
        #expect(removed.accountID == saved.accountID)
    }

    @Test func diskFailurePreventsCreatingAnAccount() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([0]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let model = CreateIdentityViewModel()
        await model.configurePersistence(store: SignUpDraftStore(directory: file))
        model.displayName = "Alice"
        let service = CreateIdentityServiceStub()
        await model.submit(using: service) {}
        #expect(model.failure == .draftStorage)
        #expect(service.createCount == 0)
    }

    @Test func photoPreparationRejectsUndecodableBytes() async {
        await #expect {
            try await ProfileImageDraftProcessor.prepare(
                data: Data([0]), fileName: "broken.jpg", typeIdentifier: nil
            )
        } throws: { error in
            guard let failure = error as? MediaDraftProcessor.Failure,
                  case .unsupportedImage = failure else { return false }
            return true
        }
    }

    @Test func avatarPreparationUsesTheFixedStandardImageContract() async throws {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 3_000, height: 1_500),
            format: format
        ).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 3_000, height: 1_500))
        }
        let png = try #require(image.pngData())

        let draft = try await ProfileImageDraftProcessor.prepare(
            data: png,
            fileName: "avatar.png",
            typeIdentifier: "public.png",
            sourceURL: URL(string: "https://example.com/avatar.png")
        )

        #expect(draft.sourceURL == "https://example.com/avatar.png")
        #expect(draft.mediaType == "image/jpeg")
        #expect(draft.dim == "2048x1024")
        #expect(draft.data.count <= MediaDraftProcessor.maxImageAttachmentBytes)
        #expect(draft.thumbnail != nil)
    }

    private static let avatarDraft = GroupImageUploadDraft(
        data: Data([0x01, 0x02, 0x03]),
        mediaType: "image/jpeg",
        sourceURL: nil,
        dim: "1x1",
        thumbhash: nil,
        thumbnail: nil
    )
}

@MainActor
private final class CreateIdentityServiceStub: CreateIdentityServicing {
    var createFailuresRemaining = 0
    var removeFailuresRemaining = 0
    var removeCount = 0
    var loseRemovalReply = false
    var loseCreationReply = false
    var storedAccounts: [AccountSummaryFfi] = []
    var publishFailuresRemaining = 0
    var readinessFailuresRemaining = 0
    var uploadFailuresRemaining = 0
    var beforeReadinessReturn: (() async -> Void)?
    private(set) var readinessRequests: [(accountRef: String, retry: Bool)] = []

    private(set) var createCount = 0
    private(set) var uploadCount = 0
    private(set) var publishCount = 0
    private(set) var completeCount = 0
    var beforeCreateReturn: (() async -> Void)?
    var beforeSuggestionReturn: (() async -> Void)?
    private(set) var suggestionCount = 0
    private(set) var publishedProfile: UserProfileMetadataFfi?
    private var savedProfile: UserProfileMetadataFfi?

    var beforeAccountsReturn: (() async -> Void)?

    func listIdentityAccounts() async throws -> [AccountSummaryFfi] {
        await beforeAccountsReturn?()
        return storedAccounts
    }
    func loadIdentityProfile(accountID: String) async throws -> UserProfileMetadataFfi? { savedProfile }

    func removeUnfinishedSignUpAccount(_ account: AccountSummaryFfi) async throws {
        removeCount += 1
        if removeFailuresRemaining > 0 {
            removeFailuresRemaining -= 1
            throw StubError.failed
        }
        storedAccounts.removeAll { $0.accountIdHex == account.accountIdHex }
        if loseRemovalReply { loseRemovalReply = false; throw StubError.failed }
    }

    func suggestedProfileName() async throws -> String {
        suggestionCount += 1
        await beforeSuggestionReturn?()
        return "Suggested Name"
    }


    let identity = AccountSummaryFfi(
        label: "created",
        accountIdHex: String(repeating: "a", count: 64),
        localSigning: true,
        externalSigning: false,
        signedOut: false,
        running: true
    )

    func createIdentityForProfileSetup() async throws -> IdentityCreationResultFfi {
        createCount += 1
        if createFailuresRemaining > 0 {
            createFailuresRemaining -= 1
            throw StubError.failed
        }
        await beforeCreateReturn?()
        storedAccounts.append(identity)
        if loseCreationReply { loseCreationReply = false; throw StubError.failed }
        return IdentityCreationResultFfi(
            account: identity,
            profile: UserProfileMetadataFfi(
                name: "engine-name",
                displayName: "Engine Name",
                about: nil,
                picture: nil,
                banner: "https://example.com/banner.jpg",
                nip05: "engine@example.com",
                lud16: "engine@example.com"
            ),
            readiness: .localReady
        )
    }

    func waitForIdentityProfileSetup(accountRef: String, retry: Bool) async throws {
        readinessRequests.append((accountRef, retry))
        if readinessFailuresRemaining > 0 {
            readinessFailuresRemaining -= 1
            throw IdentitySetupReadinessWaiter.Failure.timedOut
        }
        await beforeReadinessReturn?()
    }

    func uploadOnboardingAvatar(
        accountRef: String,
        draft: GroupImageUploadDraft
    ) async throws -> String {
        uploadCount += 1
        if uploadFailuresRemaining > 0 {
            uploadFailuresRemaining -= 1
            throw StubError.failed
        }
        return "https://example.com/avatar.jpg"
    }

    func publishOnboardingProfile(
        accountRef: String,
        profile: UserProfileMetadataFfi
    ) async throws {
        publishedProfile = profile
        publishCount += 1
        if publishFailuresRemaining > 0 {
            publishFailuresRemaining -= 1
            throw StubError.failed
        }
        savedProfile = profile
    }

    func completeIdentityProfileSetup(_ summary: AccountSummaryFfi) async {
        completeCount += 1
    }

    private enum StubError: Error {
        case failed
    }
}

private actor IdentityCreationGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func waitForRelease() async {
        entered = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilEntered() async {
        while !entered {
            await Task.yield()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
