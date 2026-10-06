import Foundation
import Testing
import MarmotKit
@testable import whitenoise_ios

@MainActor
struct AccountSetupTests {
    @Test func editableProfileNeverOffersAnImplicitSaveRetry() {
        var value = snapshot()
        value.steps = [.init(step: .profile, status: .needsInput, findings: [],
                             actions: [.retry, .editDiscoveryRelays, .editProfile, .continueWithout], checkedAt: nil)]
        let presentation = AccountSetupProfilePresentation(snapshot: value)
        #expect(presentation.retryAction(failedAction: nil, hasFailure: false) == nil)
        #expect(presentation.retryAction(failedAction: nil, hasFailure: true) == .retry)
        #expect(presentation.retryAction(failedAction: .skip, hasFailure: true) == .skip)
        #expect(presentation.retryAction(failedAction: .save, hasFailure: true) == .save)
    }

    @Test func editingAfterAFailedSaveRemovesInlineRetryUntilTheNextFailure() {
        var value = proposalSnapshot(step: .profile)
        var presentation = AccountSetupProfilePresentation(snapshot: value)
        #expect(presentation.retryAction(failedAction: .save, hasFailure: true, draftWasEdited: true) == nil)
        #expect(presentation.retryAction(failedAction: .save, hasFailure: true, draftWasEdited: false) == .save)
        #expect(presentation.retryAction(failedAction: .cancelRepair, hasFailure: true, draftWasEdited: true) == .cancelRepair)

        value.steps[0].actions = [.retry]
        presentation = AccountSetupProfilePresentation(snapshot: value)
        #expect(presentation.retryAction(failedAction: .save, hasFailure: true, draftWasEdited: true) == .retry)
    }

    @Test func pendingProfileDiscardRecognizesTheRefreshedCheckpoint() {
        var value = proposalSnapshot(step: .profile)
        let pending = AccountSetupProfilePresentation.PendingDiscard(snapshot: value)
        #expect(!pending.isComplete(in: value))
        value.revision += 1
        #expect(!pending.isComplete(in: value))
        // Cancellation can commit before the suspended UI receives its completion.
        value.proposal = nil
        #expect(pending.isComplete(in: value))
        #expect(value.steps[0].status == .needsInput)

        value.revision = 8
        #expect(!pending.isComplete(in: value))
        value.revision = 9
        value.recoveryEpoch = "another-attempt"
        #expect(!pending.isComplete(in: value))
        value.recoveryEpoch = nil
        value.accountIdHex = String(repeating: "b", count: 64)
        #expect(!pending.isComplete(in: value))
    }

    @Test func profileRetryRespectsChangesToOfferedActions() {
        var value = proposalSnapshot(step: .profile)
        var presentation = AccountSetupProfilePresentation(snapshot: value)
        #expect(presentation.retryAction(failedAction: .cancelRepair, hasFailure: true) == .cancelRepair)

        // Once publication starts, the previous draft is immutable and cannot be skipped or cancelled.
        value.steps[0].actions = [.retry]
        presentation = AccountSetupProfilePresentation(snapshot: value)
        #expect(presentation.retryAction(failedAction: .save, hasFailure: true) == .retry)
        #expect(presentation.retryAction(failedAction: .skip, hasFailure: true) == .retry)
        #expect(presentation.retryAction(failedAction: .cancelRepair, hasFailure: true) == .retry)

        value.steps[0].actions = []
        presentation = AccountSetupProfilePresentation(snapshot: value)
        #expect(presentation.retryAction(failedAction: .cancelRepair, hasFailure: true) == nil)
    }

    @Test func discardingAProfileProposalClosesOnlyAfterConfirmedCancellation() {
        var value = proposalSnapshot(step: .profile)
        #expect(!AccountSetupProfilePresentation.shouldDismiss(after: .cancelRepair, snapshot: value, errorMessage: nil))

        // MDK returns NeedsInput with no proposal after cancellation, not Passed or Skipped.
        value.proposal = nil
        value.steps[0].actions = [.retry, .editProfile, .continueWithout]
        #expect(AccountSetupProfilePresentation.shouldDismiss(after: .cancelRepair, snapshot: value, errorMessage: nil))
        #expect(!AccountSetupProfilePresentation.shouldDismiss(after: .cancelRepair, snapshot: value, errorMessage: "Cancellation failed"))
        #expect(!AccountSetupProfilePresentation.shouldDismiss(after: .skip, snapshot: value, errorMessage: nil))

        value.steps[0].status = .skipped
        #expect(AccountSetupProfilePresentation.shouldDismiss(after: .skip, snapshot: value, errorMessage: nil))
        #expect(!AccountSetupProfilePresentation.shouldDismiss(after: .skip, snapshot: value, errorMessage: "Skip failed"))
    }

    @Test func profileLookupFailureDoesNotOfferEditing() {
        var value = snapshot()
        value.steps = [.init(step: .profile, status: .retryableFailure, findings: [],
                             actions: [.retry, .continueWithout], checkedAt: nil)]
        let presentation = AccountSetupProfilePresentation(snapshot: value)
        #expect(!presentation.canEdit)
        #expect(presentation.canRetry)
        #expect(presentation.canSkip)
        #expect(presentation.profile == nil)
    }

    @Test func profileDraftRemainsReadOnlyWhilePublicationIsInterrupted() {
        var value = snapshot()
        value.steps = [.init(step: .profile, status: .retryableFailure, findings: [],
                             actions: [.retry], checkedAt: nil)]
        let profile = UserProfileMetadataFfi(name: "Alex", displayName: nil, about: nil,
                                            picture: nil, banner: nil, nip05: nil, lud16: nil)
        value.proposal = .init(step: .profile, revision: value.revision, previousEventId: nil,
                               readRelays: [], writeRelays: [], profile: profile, follows: nil)
        let interrupted = AccountSetupProfilePresentation(snapshot: value)
        #expect(interrupted.isInterrupted)
        #expect(interrupted.profile == profile)
        #expect(!interrupted.canEdit && !interrupted.canSkip)
        #expect(interrupted.canRetry)

        value.steps[0].actions = [.approveRepair, .cancelRepair]
        let editable = AccountSetupProfilePresentation(snapshot: value)
        #expect(!editable.isInterrupted)
        #expect(editable.canEdit && editable.canCancelRepair)
        #expect(!editable.canRetry && !editable.canSkip)
    }

    @Test func optionalProfileFormDoesNotUseAnUnrelatedRepairProposal() {
        var value = snapshot()
        value.steps = [.init(step: .profile, status: .needsInput, findings: [],
                             actions: [.editProfile, .continueWithout], checkedAt: nil)]
        value.proposal = .init(step: .relays, revision: value.revision, previousEventId: nil,
                               readRelays: ["wss://relay.example.com"], writeRelays: [], profile: nil, follows: nil)
        let presentation = AccountSetupProfilePresentation(snapshot: value)
        #expect(presentation.canEdit && presentation.canSkip)
        #expect(!presentation.isInterrupted)
        #expect(presentation.profile == nil)
    }

    @Test func profileOptionalityFollowsTheOfferedActions() {
        var step = snapshot().steps[0]
        step.step = .profile
        step.findings = [.init(issue: .missing, endpoint: nil)]
        step.actions = [.editProfile, .continueWithout]
        #expect(AccountSetupPresentation.checkState(step) == .optionalReview)

        step.status = .retryableFailure
        step.findings = [.init(issue: .timedOut, endpoint: nil)]
        step.actions = [.retry, .continueWithout]
        #expect(AccountSetupPresentation.checkState(step) == .optionalReview)

        // An interrupted profile publication cannot promise a skip that MDK does not offer.
        step.findings = [.init(issue: .publicationFailed, endpoint: nil)]
        step.actions = [.retry]
        #expect(AccountSetupPresentation.checkState(step) == .requiredFix)
    }

    @Test func deviceAcknowledgmentIsDifferentFromARequiredRepair() {
        var step = snapshot().steps[0]
        #expect(AccountSetupPresentation.checkState(step) == .acknowledgment)
        step.actions = [.retry]
        step.status = .retryableFailure
        #expect(AccountSetupPresentation.checkState(step) == .requiredFix)

        step.step = .relays
        step.actions = [.useRecommendedRelays, .editDiscoveryRelays]
        #expect(AccountSetupPresentation.checkState(step) == .requiredFix)
    }

    @Test func errorsPreserveTheExplanationAndIdentifyFailedClose() {
        let error = L10n.string("Couldn’t close sign-in. Try again when the current update has finished.")
        let header = AccountSetupPresentation.header(
            snapshot(ready: true), reviewStep: nil, errorMessage: error, isOpeningChats: false, closeFailed: true
        )
        #expect(header.title == L10n.string("Couldn’t close sign-in"))
        #expect(header.subtitle == error)

        let refreshError = L10n.string("Couldn’t refresh your accounts. Try again.")
        let opening = AccountSetupPresentation.header(
            snapshot(ready: true), reviewStep: nil, errorMessage: refreshError, isOpeningChats: true, closeFailed: false
        )
        #expect(opening.title == L10n.string("Couldn’t continue signing in"))
        #expect(opening.subtitle == refreshError)
    }

    @Test func readyHeaderDistinguishesOpeningFromReady() {
        let ready = AccountSetupPresentation.header(
            snapshot(ready: true), reviewStep: nil, errorMessage: nil, isOpeningChats: false, closeFailed: false
        )
        let opening = AccountSetupPresentation.header(
            snapshot(ready: true), reviewStep: nil, errorMessage: nil, isOpeningChats: true, closeFailed: false
        )
        #expect(ready.title == L10n.string("You’re ready to chat"))
        #expect(opening.title == ready.title)
        #expect(ready.subtitle == L10n.string("Open Chats to start messaging."))
        #expect(opening.subtitle == L10n.string("Opening your chats…"))
    }

    @Test func reviewPromptRequiresAnAvailableCurrentDecision() {
        var current = snapshot()
        var profile = current.steps[0]
        profile.step = .profile
        profile.status = .checking
        profile.actions = []
        current.steps.insert(profile, at: 0)
        let queued = AccountSetupPresentation.header(
            current, reviewStep: AccountSetupPresentation.stepToReview(current, isBusy: false, isConnected: true),
            errorMessage: nil, isOpeningChats: false, closeFailed: false
        )
        #expect(queued.title == L10n.string("Getting ready to chat"))
        #expect(queued.subtitle == L10n.string("We’re checking your profile and connection."))

        current.steps[0].status = .skipped
        let disconnected = AccountSetupPresentation.stepToReview(current, isBusy: false, isConnected: false)
        #expect(disconnected == nil)
        let reconnecting = AccountSetupPresentation.header(
            current, reviewStep: disconnected, errorMessage: nil, isOpeningChats: false, closeFailed: false
        )
        #expect(reconnecting.title == queued.title)
        #expect(reconnecting.subtitle == queued.subtitle)

        let connected = AccountSetupPresentation.header(
            current, reviewStep: AccountSetupPresentation.stepToReview(current, isBusy: false, isConnected: true),
            errorMessage: nil, isOpeningChats: false, closeFailed: false
        )
        #expect(connected.title == L10n.string("A little more to do"))
        #expect(connected.subtitle == L10n.string("Review the item below to continue."))
    }

    @Test func reviewDestinationFollowsTheCurrentUnfinishedCheck() {
        var current = snapshot()
        var profile = current.steps[0]
        profile.step = .profile
        profile.status = .skipped
        profile.actions = []
        current.steps.insert(profile, at: 0)
        #expect(AccountSetupPresentation.stepToReview(current, isBusy: false, isConnected: true) == .singleDevice)

        current.steps[0].status = .needsInput
        current.steps[0].actions = [.editProfile, .continueWithout]
        #expect(AccountSetupPresentation.stepToReview(current, isBusy: false, isConnected: true) == .profile)

        // A later decision must not jump ahead of the check that is still running or queued.
        current.steps[0].status = .checking
        #expect(AccountSetupPresentation.stepToReview(current, isBusy: false, isConnected: true) == nil)
        current.steps[0].status = .pending
        #expect(AccountSetupPresentation.stepToReview(current, isBusy: false, isConnected: true) == nil)
        #expect(AccountSetupPresentation.stepToReview(snapshot(), isBusy: true, isConnected: true) == nil)
        #expect(AccountSetupPresentation.stepToReview(snapshot(ready: true), isBusy: false, isConnected: true) == nil)
        #expect(AccountSetupPresentation.stepToReview(snapshot(cancellationPending: true), isBusy: false, isConnected: true) == nil)
    }

    @Test func accountRelaysAddGeneralPurposeRelaysOnlyToProductionSeeds() {
        #expect(AppContainerConfig.accountRelays(runtimeRelays: AppContainerConfig.seedRelays) == [
            "wss://relay.eu.whitenoise.chat", "wss://relay.us.whitenoise.chat",
            "wss://nos.lol", "wss://relay.primal.net", "wss://whitenoise.nostrdev.com"
        ])
        let local = ["ws://127.0.0.1:7777"]
        #expect(AppContainerConfig.accountRelays(runtimeRelays: local) == local)
    }

    @Test func failedRestartCannotReuseACancelledCheckpoint() async {
        let original = snapshot()
        await #expect(throws: MarmotKitError.OnboardingActionUnavailable) {
            try await AccountSetupRecovery.restartIfPossible(snapshot: original, cancel: {}, begin: {
                throw MarmotKitError.OnboardingActionUnavailable
            })
        }
    }

    @Test func failedCancellationCannotRestartOrApproveAnOldCheckpoint() async throws {
        let original = snapshot()
        var restarted = false
        await #expect(throws: MarmotKitError.OnboardingActionUnavailable) {
            try await AccountSetupRecovery.restartIfPossible(snapshot: original, cancel: {
                throw MarmotKitError.OnboardingActionUnavailable
            }, begin: { restarted = true; return original })
        }
        #expect(!restarted)
    }

    @Test func cancellationDuringCheckpointRecoveryPropagates() async {
        await #expect(throws: CancellationError.self) {
            try await AccountSetupRecovery.restartIfPossible(snapshot: snapshot(), cancel: {
                throw CancellationError()
            }, begin: { snapshot(ready: true) })
        }
    }

    @Test func relayFindingsNameTheAffectedAddressWithoutDuplicates() {
        let retired = OnboardingFindingFfi(issue: .retiredRelay, endpoint: "wss://relay.damus.io")
        let unreachable = OnboardingFindingFfi(issue: .unreachable, endpoint: "wss://example.com")
        #expect(AccountSetupPresentation.findingMessages([retired, retired, unreachable]) == [
            AccountSetupPresentation.issue(.retiredRelay) + "\nwss://relay.damus.io",
            AccountSetupPresentation.issue(.unreachable) + "\nwss://example.com"
        ])
    }

    @Test func relayFindingAddressesAreBoundedAndStripInvisibleFormatting() {
        let findings = [OnboardingFindingFfi(issue: .invalidRelay,
                                           endpoint: "\u{202e}wss://example.com\n" + String(repeating: "a", count: 1_000))]
        let messages = AccountSetupPresentation.findingMessages(findings)
        #expect(messages.count == 1)
        #expect(!messages[0].contains("\u{202e}"))
        #expect(messages[0].filter { $0 == "\n" }.count == 1)
        #expect(messages[0].count <= AccountSetupPresentation.issue(.invalidRelay).count + 202)
        #expect(messages[0].hasSuffix("…"))
    }

    private func snapshot(
        revision: UInt64 = 1,
        status: OnboardingStatusFfi = .needsInput,
        ready: Bool = false,
        cancellationPending: Bool = false
    ) -> OnboardingSnapshotFfi {
        OnboardingSnapshotFfi(
            accountIdHex: String(repeating: "a", count: 64), recoveryEpoch: nil, revision: revision, ready: ready,
            steps: [OnboardingStepStateFfi(
                step: .singleDevice, status: status, findings: [],
                actions: [.continueAnyway, .cancelOnboarding], checkedAt: nil
            )], proposal: nil,
            singleDeviceNotice: OnboardingSingleDeviceNoticeFfi(
                discovery: .noneFound, otherPackages: [], discoveryComplete: true, acknowledgedAt: nil
            ), cancellationPending: cancellationPending
        )
    }

    @Test func snapshotsIgnoreOlderRevisionsAndOtherAccounts() {
        let model = AccountSetupModel(snapshot: snapshot(revision: 5))
        model.apply(snapshot(revision: 4, ready: true))
        #expect(!model.snapshot.ready)
        var foreign = snapshot(revision: 6, ready: true)
        foreign.accountIdHex = String(repeating: "b", count: 64)
        model.apply(foreign)
        #expect(!model.snapshot.ready)
        model.apply(snapshot(revision: 7, ready: true))
        #expect(model.snapshot.ready)
        #expect(!model.canFinish)
    }

    @Test func optionalSkipIsDistinctFromSuccess() {
        let skipped = AccountSetupPresentation.checkState(snapshot(status: .skipped).steps[0])
        let passed = AccountSetupPresentation.checkState(snapshot(status: .passed).steps[0])
        #expect(skipped == .skipped)
        #expect(passed == .passed)
        #expect(skipped.symbol != passed.symbol)
        #expect(skipped.subtitle != passed.subtitle)
    }

    @Test func analyticsReadinessWaitsForCancellationToClear() {
        let model = AccountSetupModel(snapshot: snapshot())
        var observations = 0
        model.onProductReady = { observations += 1 }
        model.apply(snapshot(revision: 2, ready: true, cancellationPending: true))
        #expect(!model.isDurablyReady)
        #expect(observations == 0)
        model.apply(snapshot(revision: 3, ready: true))
        #expect(model.isDurablyReady)
        #expect(observations == 1)
        model.apply(snapshot(revision: 4, ready: true))
        #expect(observations == 1)
    }

    @Test func deviceButtonDistinguishesCleanAndUncertainDiscovery() {
        #expect(AccountSetupPresentation.deviceAction(.noneFound) == L10n.string("Continue"))
        #expect(AccountSetupPresentation.deviceAction(.unknown) == L10n.string("Continue anyway"))
        #expect(AccountSetupPresentation.deviceAction(.otherInstallationPossible) == L10n.string("Continue anyway"))
        #expect(AccountSetupPresentation.deviceAction(nil) == L10n.string("Continue anyway"))
    }

    @Test func deviceDiscoveryCopyDistinguishesAllThreeOutcomes() {
        let labels = Set([
            AccountSetupPresentation.deviceNotice(.noneFound),
            AccountSetupPresentation.deviceNotice(.unknown),
            AccountSetupPresentation.deviceNotice(.otherInstallationPossible)
        ])
        #expect(labels.count == 3)
    }

    @Test func validatesRelayListsBeforeSubmitting() {
        #expect(AccountSetupInput.relays("wss://relay.example wss://relay.example") == ["wss://relay.example"])
        #expect(AccountSetupInput.relays("wss://127.0.0.1") == nil)
        #expect(AccountSetupInput.relays("https://relay.example") == nil)
        #expect(AccountSetupInput.relays("") == nil)
        #expect(AccountSetupInput.relays(String(repeating: "x", count: 16_385)) == nil)
    }

    @Test func editorSelectionLimitCountsSharedAddressesOnce() {
        let sixteen = (1...16).map { "wss://relay\($0).example" }
        #expect(!AccountSetupInput.exceedsSelectionLimit(reads: sixteen, writes: sixteen))
        #expect(AccountSetupInput.exceedsSelectionLimit(reads: sixteen, writes: ["wss://relay17.example"]))
    }

    @Test func proposalValidationRejectsTheWholeListInsteadOfHidingUnsafeEntries() {
        #expect(AccountSetupInput.proposalRelays(["wss://RELAY.example/"]) == ["wss://relay.example/"])
        for unsafe in ["ws://relay.example", "wss://user@relay.example", "wss://127.0.0.1",
                       "wss://relay.example/\u{202E}host", "wss://relay.example/\n"] {
            #expect(AccountSetupInput.proposalRelays(["wss://safe.example", unsafe]) == nil)
        }
    }

    @Test(arguments: [false, true]) func streamEndOnlyBlocksAnUnfinishedAccount(ready: Bool) async {
        let initial = snapshot()
        let client = SetupTestClient(initial: initial)
        let model = AccountSetupModel(snapshot: initial)
        await model.connect(client)
        await settle { model.isConnected && !model.isBusy }
        client.emit(snapshot(revision: 2, status: ready ? .passed : .needsInput, ready: ready))
        client.continuation.finish()
        await model.drain()
        #expect(model.canFinish == ready)
        #expect((model.errorMessage == nil) == ready)
        #expect(model.hasConnectionFailure == !ready)
        model.suspend()
        #expect(!model.hasConnectionFailure)
    }

    @Test func suspendingAfterAnActionFailureDoesNotReportAConnectionFailure() async {
        let initial = snapshot()
        let model = AccountSetupModel(snapshot: initial)
        await model.connect(SetupTestClient(initial: initial))
        await settle { model.isConnected && !model.isBusy }
        await model.send(.approve(0))?.value
        #expect(model.errorMessage != nil)
        #expect(!model.hasConnectionFailure)
        model.suspend()
        #expect(!model.isConnected)
        #expect(model.errorMessage != nil)
        #expect(!model.hasConnectionFailure)

        await model.connect(SetupTestClient(initial: initial))
        await settle { model.isConnected && !model.isBusy }
        #expect(model.isConnected)
        #expect(model.errorMessage == nil)
        #expect(!model.hasConnectionFailure)
        model.suspend()
        await model.drain()
    }

    @Test(arguments: [UInt64(4), 5]) func automaticSkipStopsOnUnchangedOrOlderResults(revision: UInt64) async {
        var initial = snapshot(revision: 5)
        initial.steps[0].step = .follows
        initial.steps[0].actions = [.continueWithout]
        var unchanged = initial
        unchanged.revision = revision
        let client = SetupTestClient(initial: initial, skipResult: unchanged)
        let model = AccountSetupModel(snapshot: initial)
        await model.connect(client)
        await settle { model.errorMessage != nil }
        #expect(model.errorMessage != nil)
        #expect(await client.skipCount == 1)
        #expect(!model.isBusy)
        model.suspend()
        await model.drain()
    }

    @Test func quietSnapshotPollerCancelsWithoutEmitting() async {
        let quiet = snapshot(revision: 3)
        let readGate = SetupOperationGate()
        let (reads, readSignal) = AsyncStream.makeStream(of: Void.self)
        let poller = AccountSetupSnapshotPoller(snapshot: quiet) {
            readSignal.yield()
            await readGate.wait()
            // Cancelled mid-read: dropping this newer revision is the post-read check's job.
            var read = quiet
            read.revision += 1
            return read
        }
        let waiting = Task { try await poller.next() }
        var iterator = reads.makeAsyncIterator()
        await iterator.next()
        waiting.cancel()
        await readGate.release()
        await #expect(throws: CancellationError.self) { _ = try await waiting.value }
    }

    @Test func missingFollowsAreSkippedWithoutPublishing() async {
        var initial = snapshot()
        initial.steps[0].step = .follows
        initial.steps[0].actions = [.continueWithout, .editFollows]
        let client = SetupTestClient(initial: initial)
        let model = AccountSetupModel(snapshot: initial)
        await model.connect(client)
        await settle { model.snapshot.steps[0].status == .skipped }
        #expect(model.snapshot.steps[0].status == .skipped)
        #expect(await client.skipCount == 1)
        #expect(await client.approvalCount == 0)
        model.suspend()
        await model.drain()
    }

    @Test func profileIsNeverAutomaticallySkippedOrPublished() {
        var value = snapshot()
        value.steps[0].step = .profile
        value.steps[0].actions = [.continueWithout, .editProfile]
        #expect(AccountSetupPolicy.automaticAction(value) == nil)
    }

    @Test(arguments: [OnboardingStepFfi.relays, .inboxRelays], [false, true])
    func anotherRelayLookupPreservesTheReturnedRecoveryChoices(
        step: OnboardingStepFfi, lookupFailed: Bool
    ) async {
        var initial = snapshot()
        initial.steps[0].step = step
        initial.steps[0].actions = [.editDiscoveryRelays, .useRecommendedRelays]
        var result = initial
        result.revision += 1
        result.steps[0].status = lookupFailed ? .retryableFailure : .needsInput
        result.steps[0].findings = [OnboardingFindingFfi(
            issue: lookupFailed ? .unreachable : .missing, endpoint: nil
        )]
        result.steps[0].actions = [.retry, .editDiscoveryRelays]
        if !lookupFailed { result.steps[0].actions.append(.useRecommendedRelays) }
        let client = SetupTestClient(initial: initial, discoveryResult: result)
        let model = AccountSetupModel(snapshot: initial)
        await model.connect(client)
        await settle { model.isConnected && !model.isBusy }

        let lookup = model.send(.discovery(["wss://another.example"]))
        #expect(lookup != nil)
        await lookup?.value

        #expect(model.currentStep?.step == step)
        #expect(model.currentStep?.status == result.steps[0].status)
        #expect(model.offeredActions.contains(.useRecommendedRelays) == !lookupFailed)
        #expect(model.offeredActions.contains(.editDiscoveryRelays))
        #expect(!model.isBusy)
        #expect(await client.defaultPublicationCount == 0)
        if !lookupFailed {
            let publication = model.send(.useDefaults(step))
            #expect(publication != nil)
            await publication?.value
            #expect(await client.defaultPublicationCount == 1)
            #expect(model.snapshot.steps[0].status == .passed)
        }
        model.suspend()
        await model.drain()
    }

    @Test func obsoleteUnapprovedFollowProposalIsDiscardedButApprovedWorkIsKept() {
        var value = proposalSnapshot(step: .follows)
        value.steps[0].actions = [.approveRepair, .cancelRepair]
        if case .cancelRepair = AccountSetupPolicy.automaticAction(value) {} else {
            Issue.record("Unapproved follow proposal should be discarded")
        }
        value.steps[0].actions = [.retry]
        #expect(AccountSetupPolicy.automaticAction(value) == nil)
    }

    @Test func importOptionsDiscoverOnRuntimeRelays() {
        let options = AccountSetupOptions.importOptions(runtimeRelays: AppContainerConfig.seedRelays)
        #expect(options.discoveryRelays == AppContainerConfig.seedRelays)
        #expect(options.inboxRelays == AppContainerConfig.seedRelays)
        #expect(options.defaultRelays == AppContainerConfig.accountRelays(runtimeRelays: AppContainerConfig.seedRelays))
        let local = ["ws://127.0.0.1:7777"]
        #expect(AccountSetupOptions.importOptions(runtimeRelays: local)
            == OnboardingOptionsFfi(defaultRelays: local, discoveryRelays: local, inboxRelays: local))
    }

    @Test(arguments: [OnboardingStepFfi.relays, .inboxRelays])
    func missingRelaysRequireConsent(_ step: OnboardingStepFfi) {
        var value = snapshot()
        value.steps[0].step = step
        value.steps[0].findings = [OnboardingFindingFfi(issue: .missing, endpoint: nil)]
        value.steps[0].actions = [.useRecommendedRelays]
        #expect(AccountSetupPolicy.automaticAction(value) == nil)
    }

    @Test func explicitSaveApprovesOnlyTheReturnedProposalRevision() async throws {
        let proposed = proposalSnapshot(step: .profile)
        var approvedRevision: UInt64?
        _ = try await AccountSetupPublication.publish(step: .profile, propose: { proposed }, approve: { revision, _ in
            approvedRevision = revision
            return proposed
        })
        #expect(approvedRevision == proposed.revision)
    }

    @Test(arguments: [OnboardingStepFfi.relays, .inboxRelays])
    func relayEditorRequiresApproval(_ step: OnboardingStepFfi) async {
        var initial = snapshot()
        initial.steps[0].step = step
        initial.steps[0].actions = [.editRelays, .retry]
        let client = SetupTestClient(initial: initial)
        let model = AccountSetupModel(snapshot: initial)
        await model.connect(client)
        await settle { model.isConnected && !model.isBusy }
        #expect(!model.offeredActions.contains(.useRecommendedRelays))
        #expect(await client.approvalCount == 0)

        let reads = ["wss://read.example"]
        let writes = step == .relays ? ["wss://write.example"] : []
        let operation = model.send(.editRelays(step, reads: reads, writes: writes))
        #expect(operation != nil)
        await operation?.value

        #expect(model.snapshot.proposal?.readRelays == reads)
        #expect(model.snapshot.proposal?.writeRelays == writes)
        #expect(model.offeredActions.contains(.approveRepair))
        #expect(AccountSetupPolicy.automaticAction(model.snapshot) == nil)
        #expect(await client.approvalCount == 0)
        #expect(await client.defaultPublicationCount == 0)
        model.suspend()
        await model.drain()
    }

    @Test func recoveredPublicationUsesTheEpochOfTheDisplayedProposal() async throws {
        var proposed = proposalSnapshot(step: .profile)
        proposed.recoveryEpoch = "recovered-epoch"
        var approved: (UInt64, String?)?
        _ = try await AccountSetupPublication.publish(step: .profile, propose: { proposed }, approve: { revision, epoch in
            approved = (revision, epoch)
            return proposed
        })
        #expect(approved?.0 == proposed.revision)
        #expect(approved?.1 == proposed.recoveryEpoch)
        let model = AccountSetupModel(snapshot: proposed)
        var stale = proposed
        stale.recoveryEpoch = "older-epoch"
        stale.revision += 100
        model.apply(stale)
        #expect(model.snapshot == proposed)
    }

    @Test func approvedProfileRetryFreezesThePreviouslySavedDraft() {
        var value = proposalSnapshot(step: .profile)
        let model = AccountSetupModel(snapshot: value)
        #expect(!model.isResumingProfilePublication)
        value.steps[0].actions = [.retry]
        model.apply(value)
        #expect(model.isResumingProfilePublication)
    }

    @Test func mismatchedProposalIsNeverApproved() async {
        let proposed = proposalSnapshot(step: .relays)
        var approved = false
        await #expect(throws: MarmotKitError.self) {
            _ = try await AccountSetupPublication.publish(step: .profile, propose: { proposed }, approve: { _, _ in
                approved = true
                return proposed
            })
        }
        #expect(!approved)
    }

    @Test func interruptedSaveDoesNotApproveAnUnpublishedProposal() async {
        let proposed = proposalSnapshot(step: .profile)
        var approved = false
        let task = Task {
            try await AccountSetupPublication.publish(step: .profile, propose: {
                withUnsafeCurrentTask { $0?.cancel() }
                return proposed
            }, approve: { _, _ in
                approved = true
                return proposed
            })
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(!approved)
    }

    @Test(arguments: [false, true]) func profileSheetOnlyClosesAfterSuccessfulSave(fails: Bool) async {
        var initial = snapshot()
        initial.steps[0].step = .profile
        let client = SetupTestClient(initial: initial, profileSaveFails: fails)
        let model = AccountSetupModel(snapshot: initial)
        await model.connect(client)
        await settle { model.isConnected && !model.isBusy }
        let profile = UserProfileMetadataFfi(name: "Alex", displayName: "Alex", about: nil, picture: nil, nip05: nil, lud16: nil)
        let saved = await model.saveProfile(profile, avatar: nil)
        #expect(saved == !fails)
        model.suspend()
        await model.drain()
    }

    private func proposalSnapshot(step: OnboardingStepFfi) -> OnboardingSnapshotFfi {
        var value = snapshot(revision: 8)
        value.steps[0].step = step
        value.steps[0].actions = [.approveRepair, .cancelRepair]
        value.proposal = OnboardingRepairProposalFfi(step: step, revision: 8, previousEventId: nil,
                                                   readRelays: [], writeRelays: [], profile: nil, follows: nil)
        return value
    }

    @Test func connectionRunsChecksButNeverAcknowledgesNoticeAutomatically() async {
        let initial = snapshot()
        let client = SetupTestClient(initial: initial)
        let model = AccountSetupModel(snapshot: initial)
        await model.connect(client)
        await settle { await client.runCount == 1 && !model.isBusy }
        #expect(await client.runCount == 1)
        #expect(await client.acknowledgments.isEmpty)
        #expect(!model.snapshot.ready)
        model.send(.acknowledge(1))
        await settle { model.snapshot.ready }
        #expect(await client.acknowledgments == [1])
        #expect(model.snapshot.ready)
        model.suspend()
        await model.drain()
    }

    @Test func reconnectReplacesSubscriptionAndResumesPersistedSnapshot() async {
        let old = SetupTestClient(initial: snapshot())
        let fresh = SetupTestClient(initial: snapshot(revision: 9, status: .passed, ready: true))
        let model = AccountSetupModel(snapshot: snapshot())
        await model.connect(old)
        await settle { model.isConnected && !model.isBusy }
        model.suspend()
        await model.drain()
        await model.connect(fresh)
        await settle { model.snapshot.revision == 9 }
        #expect(model.snapshot.ready)
        old.emit(snapshot(revision: 10, ready: false))
        await Task.yield()
        #expect(model.snapshot.ready)
        model.suspend()
        await model.drain()
    }

    @Test func interruptedCancellationResumesCancellationRatherThanChecks() async {
        let initial = snapshot(cancellationPending: true)
        let client = SetupTestClient(initial: initial)
        let model = AccountSetupModel(snapshot: initial)
        await model.connect(client)
        await settle { model.cancelled }
        #expect(model.cancelled)
        #expect(await client.runCount == 0)
        #expect(await client.cancelCount == 1)
        model.suspend()
        await model.drain()
    }

    @Test func suspensionWaitsForWorkAlreadyBeingDrainedByReconnect() async {
        let gate = SetupOperationGate()
        let old = SetupTestClient(initial: snapshot(), runGate: gate)
        let fresh = SetupTestClient(initial: snapshot())
        let model = AccountSetupModel(snapshot: snapshot())
        await model.connect(old)
        await settle { await old.runCount == 1 }
        var reconnectStarted = false
        let reconnect = Task {
            reconnectStarted = true
            await model.connect(fresh)
        }
        await settle { reconnectStarted }
        var suspensionDrained = false
        let suspension = Task {
            model.suspend()
            await model.drain()
            suspensionDrained = true
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(!suspensionDrained)
        await gate.release()
        await reconnect.value
        await suspension.value
        #expect(suspensionDrained)
        #expect(!model.isConnected)
        #expect(await fresh.runCount == 0)
    }

    @Test func staleApprovalDoesNotAdvanceOrRepeatPublication() async {
        let initial = snapshot()
        let client = SetupTestClient(initial: initial)
        let model = AccountSetupModel(snapshot: initial)
        await model.connect(client)
        await settle { await client.runCount == 1 && !model.isBusy }
        model.send(.approve(0))
        model.send(.approve(0))
        await settle { model.errorMessage != nil && !model.isBusy }
        #expect(await client.approvalCount == 1)
        #expect(model.errorMessage != nil)
        #expect(!model.snapshot.ready)
        #expect(model.snapshot.revision == 1)
        model.suspend()
        await model.drain()
    }

    private func settle(_ predicate: () async -> Bool) async {
        for _ in 0..<1_000 {
            if await predicate() { return }
            await Task.yield()
        }
    }
}

/// Runs off the MainActor so the real runtime's hops do not queue behind the
/// rest of the in-process parallel suite on a starved CI runner.
struct AccountSetupRuntimeTests {
    // The poller's cancellation semantics are covered deterministically above;
    // this limit only turns an uncancellable wait into a failure instead of a
    // stalled job. Starved CI runners have taken 357s for a single real-runtime
    // test, so keep it well above that.
    @Test(.timeLimit(.minutes(10))) func realSnapshotSubscriptionCancelsWhileMDKIsQuiet() async throws {
        let client = try MarmotClient.testClient()
        try await client.startRuntime()
        let initial = try await client.marmot.beginOnboarding(
            nsec: "nsec1afh3nysthqh47awpdewcw59wvvp499f8dvlyclmnv4gvpxdk56dsa6eqsn",
            options: OnboardingOptionsFfi(defaultRelays: ["wss://relay.invalid.test"], discoveryRelays: ["wss://relay.invalid.test"])
        )
        let subscription = try await MarmotAccountSetupClient(client: client, accountID: initial.accountIdHex).subscribe()
        let waiting = Task { try await subscription.next() }
        await Task.yield()
        waiting.cancel()
        await #expect(throws: CancellationError.self) { _ = try await waiting.value }
        // Cancellation must finish without closing the live runtime or emitting another snapshot.
        #expect(try await client.onboardingSnapshot(accountID: initial.accountIdHex)?.revision == initial.revision)
        try await client.marmot.shutdownAndClose()
    }
}

private actor SetupTestClient: AccountSetupClient {
    let initial: OnboardingSnapshotFfi
    let stream: AsyncStream<OnboardingSnapshotFfi>
    nonisolated let continuation: AsyncStream<OnboardingSnapshotFfi>.Continuation
    var runCount = 0
    var cancelCount = 0
    var approvalCount = 0
    var skipCount = 0
    var defaultPublicationCount = 0
    let profileSaveFails: Bool
    let discoveryResult: OnboardingSnapshotFfi?
    let skipResult: OnboardingSnapshotFfi?
    var acknowledgments: [UInt64] = []
    let runGate: SetupOperationGate?

    init(
        initial: OnboardingSnapshotFfi, runGate: SetupOperationGate? = nil,
        profileSaveFails: Bool = false, discoveryResult: OnboardingSnapshotFfi? = nil,
        skipResult: OnboardingSnapshotFfi? = nil
    ) {
        self.initial = initial
        self.profileSaveFails = profileSaveFails
        self.discoveryResult = discoveryResult
        self.skipResult = skipResult
        self.runGate = runGate
        (stream, continuation) = AsyncStream.makeStream(of: OnboardingSnapshotFfi.self)
    }

    nonisolated func emit(_ value: OnboardingSnapshotFfi) { continuation.yield(value) }

    func subscribe() async throws -> AccountSetupSubscription {
        AccountSetupSubscription(snapshot: initial, next: { [stream] in
            for await update in stream { return update }
            return nil
        })
    }

    func perform(_ command: AccountSetupCommand) async throws -> OnboardingSnapshotFfi? {
        switch command {
        case .run:
            runCount += 1
            await runGate?.wait()
        case .discovery: return discoveryResult ?? initial
        case .editRelays(let step, let reads, let writes):
            var value = initial
            value.revision += 1
            value.steps[0].actions = [.approveRepair, .cancelRepair]
            value.proposal = OnboardingRepairProposalFfi(
                step: step, revision: value.revision, previousEventId: nil,
                readRelays: reads, writeRelays: writes, profile: nil, follows: nil
            )
            return value
        case .useDefaults:
            defaultPublicationCount += 1
            var value = discoveryResult ?? initial
            value.revision += 1
            value.steps[0].status = .passed
            return value
        case .skip(let step):
            skipCount += 1
            if let skipResult { return skipResult }
            var value = initial
            value.revision += 1
            if let index = value.steps.firstIndex(where: { $0.step == step }) {
                value.steps[index].status = .skipped
            }
            return value
        case .saveProfile:
            var value = initial
            value.revision += 1
            value.steps[0].status = profileSaveFails ? .retryableFailure : .passed
            return value
        case .cancel: cancelCount += 1; return nil
        case .approve:
            approvalCount += 1
            throw MarmotKitError.OnboardingActionUnavailable
        case .acknowledge(let revision, _):
            acknowledgments.append(revision)
            var ready = initial
            ready.revision += 1
            ready.ready = true
            return ready
        default: break
        }
        return initial
    }
}

private actor SetupOperationGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
