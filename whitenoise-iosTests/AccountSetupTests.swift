import Foundation
import Testing
import MarmotKit
@testable import whitenoise_ios

@MainActor
struct AccountSetupTests {
    private func snapshot(
        revision: UInt64 = 1,
        status: OnboardingStatusFfi = .needsInput,
        ready: Bool = false,
        cancellationPending: Bool = false
    ) -> OnboardingSnapshotFfi {
        OnboardingSnapshotFfi(
            accountIdHex: String(repeating: "a", count: 64), revision: revision, ready: ready,
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
        #expect(AccountSetupPresentation.symbol(.skipped) != AccountSetupPresentation.symbol(.passed))
        #expect(AccountSetupPresentation.status(.skipped) != AccountSetupPresentation.status(.passed))
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
        model.suspend()
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

    @Test(.timeLimit(.minutes(1))) func realSnapshotSubscriptionCancelsWhileMDKIsQuiet() async throws {
        let client = try MarmotClient.testClient()
        try await client.startRuntime()
        let initial = try await client.marmot.beginOnboarding(
            nsec: "nsec1afh3nysthqh47awpdewcw59wvvp499f8dvlyclmnv4gvpxdk56dsa6eqsn",
            options: OnboardingOptionsFfi(defaultRelays: MarmotClient.seedRelays, discoveryRelays: MarmotClient.seedRelays)
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

    @Test func explicitSaveApprovesOnlyTheReturnedProposalRevision() async throws {
        let proposed = proposalSnapshot(step: .profile)
        var approvedRevision: UInt64?
        _ = try await AccountSetupPublication.publish(step: .profile, propose: { proposed }, approve: { revision in
            approvedRevision = revision
            return proposed
        })
        #expect(approvedRevision == proposed.revision)
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
            _ = try await AccountSetupPublication.publish(step: .profile, propose: { proposed }, approve: { _ in
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
            }, approve: { _ in
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
        case .acknowledge(let revision):
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
