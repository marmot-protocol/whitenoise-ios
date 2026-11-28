import Testing
import MarmotKit
@testable import whitenoise_ios

/// How `AttachmentPolicyBridge.synchronize` wires its decisions against a
/// runtime: revoking in event order, forwarding only the generation it began,
/// keeping policy writes in event order, stopping an event that a newer one
/// superseded while the account list, a policy read or a policy write was
/// pending, and keeping it from reporting a grant that was pending. The
/// decisions themselves are in `AttachmentPolicyBridgeTests`.
// The limit sits above two chained 30-second latch waits, so their own
// timeouts report first.
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct AttachmentPolicyBridgeWiringTests {
    private static let alice = accountSummary("alice", byte: "aa")
    private static let bob = accountSummary("bob", byte: "bb")
    private static let carol = accountSummary("carol", byte: "cc", signedOut: true)
    private static let dave = accountSummary("dave", byte: "dd")
    private static let erin = accountSummary("erin", byte: "ee")

    /// Separate app owners must not share the cancellation epoch, even while
    /// one startup is parked and the other owner finishes and detaches.
    @Test func independentAppStatesDoNotCancelEachOthersStartupSync() async throws {
        let firstState = AppState.test()
        let secondState = AppState.test()
        let first = FakeAttachmentRuntime(accounts: [Self.alice], stored: attachmentPolicy(automatic: false))
        let second = FakeAttachmentRuntime(accounts: [Self.bob])
        let hold = first.hold(.listing)
        defer { hold.release.signal() }
        let startup = try await start(firstState.attachmentPolicyBridge, first, beforeStart: true)
        try await hold.entered.wait()

        let otherStartup = try await start(secondState.attachmentPolicyBridge, second, beforeStart: true)
        let detached = secondState.attachmentPolicyBridge.detach(client: second)
        hold.release.signal()
        _ = try? await detached?.value
        do { try await otherStartup.value } catch is CancellationError {}
        try await startup.value

        #expect(first.writes.map(\.policy.automatic) == [true])
        #expect(first.grants.isEmpty)
        try await firstState.attachmentPolicyBridge.synchronize(first)
        #expect(firstState.attachmentPolicyBridge.isAttached(to: first))
        #expect(first.grants.map(\.account) == [Self.alice.accountIdHex])
    }

    @Test func eachGrantForwardsTheGenerationItsEventBeganAndTheCapturedPermission() async throws {
        let runtime = FakeAttachmentRuntime(accounts: [Self.alice, Self.bob])
        let permissions = FakePermissionSource()
        let bridge = AttachmentPolicyBridge(permissions: { permissions })

        try await bridge.synchronize(runtime)

        #expect(runtime.grants.map(\.generation) == runtime.begun.map(\.generation))
        #expect(runtime.grants.map(\.account) == [Self.alice.accountIdHex, Self.bob.accountIdHex])
        for grant in runtime.grants {
            #expect(grant.permission == permissions.attachmentPermission(accountID: grant.account))
        }
        #expect(permissions.appliedCount == 1)
    }

    @Test func revokeAndDetachRevokesEverySignedInAccountWithoutGranting() async throws {
        let runtime = FakeAttachmentRuntime(accounts: [Self.alice, Self.bob, Self.carol])
        let permissions = FakePermissionSource()
        let bridge = AttachmentPolicyBridge(permissions: { permissions })

        try await bridge.synchronize(runtime)
        #expect(bridge.isAttached(to: runtime))
        #expect(runtime.grants.count == 2)
        #expect(runtime.begun.map(\.account) == [Self.alice.accountIdHex, Self.bob.accountIdHex])

        await bridge.revokeAndDetach(client: runtime)

        #expect(!bridge.isAttached(to: runtime))
        #expect(runtime.begun.map(\.account) == [
            Self.alice.accountIdHex,
            Self.bob.accountIdHex,
            Self.alice.accountIdHex,
            Self.bob.accountIdHex,
        ])
        #expect(runtime.grants.count == 2)
    }

    @Test func aNewerEventRevokesOnlyAfterTheEarlierRevocation() async throws {
        let runtime = FakeAttachmentRuntime(accounts: [Self.alice])
        let bridge = AttachmentPolicyBridge(permissions: { FakePermissionSource() })
        let hold = runtime.hold(.listing)

        let first = try await start(bridge, runtime)
        try await hold.entered.wait()
        let second = try await start(bridge, runtime)
        hold.release.signal()
        try await first.value
        try await second.value

        // The earlier event began first, so the current event's generation is the
        // second one; a newer revocation that ran ahead would have taken the first.
        // The newer revocation was queued on the main actor before the release, and
        // the main queue runs jobs in order, so one that didn't wait would run
        // first. Swift doesn't promise that order; it decides only how reliably a
        // broken bridge fails here, never whether a correct one passes.
        #expect(try runtime.grants.map(\.generation) == [runtime.secondGeneration()])
    }

    /// The superseded event is a save, so it must also fail as cancelled rather
    /// than report saved limits it never wrote.
    @Test func aSaveSupersededDuringItsPolicyReadNeitherWritesNorGrantsAndFails() async throws {
        let runtime = FakeAttachmentRuntime(accounts: [Self.alice], stored: attachmentPolicy(automatic: false))
        let permissions = FakePermissionSource()
        let bridge = AttachmentPolicyBridge(permissions: { permissions })
        let hold = runtime.hold(.read)
        let edited = attachmentPolicy(transfer: 8 * mebibyte)

        let save = try await start(bridge, runtime, updatedLimits: (Self.alice.accountIdHex, edited))
        try await hold.entered.wait()
        let resync = try await start(bridge, runtime)
        hold.release.signal()
        await #expect(throws: CancellationError.self) { try await save.value }
        try await resync.value

        // Only the resync wrote, with the stored limits.
        #expect(runtime.writes.map(\.policy.transferLimit) == [attachmentPolicy().transferLimit])
        #expect(try runtime.grants.map(\.generation) == [runtime.secondGeneration()])
        #expect(permissions.appliedCount == 1)
    }

    @Test func anEventSupersededDuringThePolicyWriteGrantsNothing() async throws {
        let runtime = FakeAttachmentRuntime(accounts: [Self.alice], stored: attachmentPolicy(automatic: false))
        let bridge = AttachmentPolicyBridge(permissions: { FakePermissionSource() })
        let hold = runtime.hold(.write)

        let first = try await start(bridge, runtime)
        try await hold.entered.wait()
        let second = try await start(bridge, runtime)
        hold.release.signal()
        try await first.value
        try await second.value

        #expect(try runtime.grants.map(\.generation) == [runtime.secondGeneration()])
    }

    @Test func anEventSupersededDuringItsGrantDoesNotReportIt() async throws {
        let runtime = FakeAttachmentRuntime(accounts: [Self.alice])
        let permissions = FakePermissionSource()
        let bridge = AttachmentPolicyBridge(permissions: { permissions })
        let hold = runtime.hold(.grant)

        let first = try await start(bridge, runtime)
        try await hold.entered.wait()
        let second = try await start(bridge, runtime)
        hold.release.signal()
        try await first.value
        try await second.value

        // Both grants reached the runtime; only the current event reports one.
        #expect(runtime.grants.count == 2)
        #expect(permissions.appliedCount == 1)
    }

    @Test func policyWritesStayInEventOrder() async throws {
        let runtime = FakeAttachmentRuntime(accounts: [Self.alice], stored: attachmentPolicy(automatic: false))
        let bridge = AttachmentPolicyBridge(permissions: { FakePermissionSource() })
        let hold = runtime.hold(.write)
        let edited = attachmentPolicy(transfer: 8 * mebibyte)

        let first = try await start(bridge, runtime)
        try await hold.entered.wait()
        let save = try await start(bridge, runtime, updatedLimits: (Self.alice.accountIdHex, edited))
        // The newer revocation doesn't wait for the held write. Once it has run,
        // the save's application is queued on the main actor ahead of the
        // release, so on the in-order main queue a write that didn't wait would
        // land first.
        try await eventually { runtime.begun.count == 2 }
        hold.release.signal()
        try await first.value
        try await save.value

        #expect(runtime.writes.map(\.policy.transferLimit) == [attachmentPolicy().transferLimit, edited.transferLimit])
    }

    @Test func editedLimitsReachOnlyTheAccountTheyName() async throws {
        let runtime = FakeAttachmentRuntime(accounts: [Self.alice, Self.bob])
        let bridge = AttachmentPolicyBridge(permissions: { FakePermissionSource() })
        let edited = attachmentPolicy(transfer: 8 * mebibyte)

        // Bob, whom the limits don't name, comes after Alice; the save must still count
        // as applied.
        try await bridge.synchronize(runtime, updatedLimits: (Self.alice.accountIdHex, edited))

        #expect(runtime.writes.map(\.account) == [Self.alice.accountIdHex])
        #expect(runtime.writes.map(\.policy.transferLimit) == [edited.transferLimit])
    }

    /// Settings must report a save as failed when its account isn't configured.
    @Test func aSaveForAnAccountStillInOnboardingIsUnavailable() async throws {
        let runtime = FakeAttachmentRuntime(accounts: [Self.alice, Self.bob],
                                            checkpoints: [Self.bob.accountIdHex: .unready])
        let bridge = AttachmentPolicyBridge(permissions: { FakePermissionSource() })
        let edited = attachmentPolicy(transfer: 8 * mebibyte)

        await #expect(throws: AttachmentReadError.unavailable) {
            try await bridge.synchronize(runtime, updatedLimits: (Self.bob.accountIdHex, edited))
        }
    }

    /// A resync that follows a save reads the policy only after the save wrote
    /// it, so it can't write the old limits back.
    @Test func aResyncAfterASaveKeepsTheSavedLimits() async throws {
        let runtime = FakeAttachmentRuntime(accounts: [Self.alice], stored: attachmentPolicy(automatic: false))
        let bridge = AttachmentPolicyBridge(permissions: { FakePermissionSource() })
        let hold = runtime.hold(.write)
        let edited = attachmentPolicy(transfer: 8 * mebibyte)

        let save = try await start(bridge, runtime, updatedLimits: (Self.alice.accountIdHex, edited))
        try await hold.entered.wait()
        let resync = try await start(bridge, runtime)
        try await eventually { runtime.begun.count == 2 }
        hold.release.signal()
        try await save.value
        try await resync.value

        #expect(runtime.writes.map(\.policy.transferLimit) == [edited.transferLimit])
        #expect(try runtime.storedPolicy(Self.alice.accountIdHex).transferLimit == edited.transferLimit)
    }

    /// The new runtime's sync starts a newer event, which supersedes the old
    /// runtime's save: the save fails and the old runtime is revoked but its
    /// policy is never read, written or granted.
    @Test func aSaveSupersededByAnotherRuntimesSyncFails() async throws {
        let old = FakeAttachmentRuntime(accounts: [Self.alice])
        let new = FakeAttachmentRuntime(accounts: [Self.alice])
        let bridge = AttachmentPolicyBridge(permissions: { FakePermissionSource() })
        let hold = old.hold(.listing)
        let limits = (account: Self.alice.accountIdHex, policy: attachmentPolicy(transfer: 8 * mebibyte))

        let save = try await start(bridge, old, updatedLimits: limits)
        try await hold.entered.wait()
        let resync = try await start(bridge, new)
        hold.release.signal()

        await #expect(throws: CancellationError.self) { try await save.value }
        try await resync.value
        #expect(old.begun.map(\.account) == [Self.alice.accountIdHex])
        #expect(old.reads.isEmpty)
        #expect(old.writes.isEmpty)
        #expect(old.grants.isEmpty)
        #expect(new.grants.map(\.account) == [Self.alice.accountIdHex])
    }

    @Test func aStartupSyncRevokesAndWritesThePolicyButGrantsNothing() async throws {
        let accounts = [Self.alice, Self.bob]
        let runtime = FakeAttachmentRuntime(accounts: accounts, stored: attachmentPolicy(automatic: false))
        let permissions = FakePermissionSource()
        let bridge = AttachmentPolicyBridge(permissions: { permissions })

        try await bridge.synchronize(runtime, beforeStart: true)

        #expect(runtime.begun.map(\.account) == accounts.map(\.accountIdHex))
        #expect(runtime.writes.map(\.account) == accounts.map(\.accountIdHex))
        #expect(!runtime.writes.map(\.policy.automatic).contains(false))
        #expect(runtime.grants.isEmpty)
        #expect(permissions.appliedCount == 0)
    }

    /// Every account is revoked; only accounts without a checkpoint or with a
    /// ready one are configured and granted. An unreadable checkpoint excludes
    /// only its own account.
    @Test func onlyAccountsPastOnboardingAreConfiguredAndGranted() async throws {
        let runtime = FakeAttachmentRuntime(
            accounts: [Self.alice, Self.erin, Self.bob, Self.dave], stored: attachmentPolicy(automatic: false),
            checkpoints: [Self.bob.accountIdHex: .unready, Self.dave.accountIdHex: .ready,
                          Self.erin.accountIdHex: .unreadable])
        let bridge = AttachmentPolicyBridge(permissions: { FakePermissionSource() })

        try await bridge.synchronize(runtime)

        let all = [Self.alice, Self.erin, Self.bob, Self.dave].map(\.accountIdHex)
        let configured = [Self.alice.accountIdHex, Self.dave.accountIdHex]
        #expect(runtime.begun.map(\.account) == all)
        #expect(runtime.writes.map(\.account) == configured)
        #expect(runtime.grants.map(\.account) == configured)
    }

    /// Defensive: `MarmotClient` reads checkpoints in a detached task, so task
    /// cancellation doesn't reach this read today. A `CancellationError` from it
    /// still ends the event instead of being treated as an unreadable checkpoint.
    @Test func aCancellationErrorFromACheckpointReadEndsTheEvent() async throws {
        let runtime = FakeAttachmentRuntime(accounts: [Self.alice, Self.bob],
                                            checkpoints: [Self.alice.accountIdHex: .cancelled])
        let bridge = AttachmentPolicyBridge(permissions: { FakePermissionSource() })

        await #expect(throws: CancellationError.self) { try await bridge.synchronize(runtime) }
        #expect(runtime.grants.isEmpty)
    }

    @Test func signedOutAccountsAreSkippedWithoutFailingTheEvent() async throws {
        let runtime = FakeAttachmentRuntime(accounts: [Self.carol, Self.alice, Self.bob],
                                            signedOutDuringRevocation: [Self.alice.accountIdHex])
        let bridge = AttachmentPolicyBridge(permissions: { FakePermissionSource() })

        try await bridge.synchronize(runtime)

        #expect(runtime.begun.map(\.account) == [Self.bob.accountIdHex])
        #expect(runtime.grants.map(\.account) == [Self.bob.accountIdHex])
    }

    @Test func aRevocationFailureOtherThanSignOutFailsTheEvent() async throws {
        let runtime = FakeAttachmentRuntime(accounts: [Self.alice, Self.bob],
                                            failingRevocation: [Self.alice.accountIdHex])
        let bridge = AttachmentPolicyBridge(permissions: { FakePermissionSource() })

        await #expect(throws: FakeAttachmentRuntime.RevocationFailed.self) { try await bridge.synchronize(runtime) }
        #expect(runtime.grants.isEmpty)
    }

    /// A failed event doesn't poison the queues: the next event still revokes
    /// and grants.
    @Test func aFailedEventDoesNotBlockTheNextOne() async throws {
        let runtime = FakeAttachmentRuntime(accounts: [Self.alice, Self.bob],
                                            checkpoints: [Self.bob.accountIdHex: .unready],
                                            failingRevocation: [Self.alice.accountIdHex])
        let bridge = AttachmentPolicyBridge(permissions: { FakePermissionSource() })
        await #expect(throws: FakeAttachmentRuntime.RevocationFailed.self) { try await bridge.synchronize(runtime) }
        runtime.failingRevocation = []
        let edited = attachmentPolicy(transfer: 8 * mebibyte)
        await #expect(throws: AttachmentReadError.unavailable) {
            try await bridge.synchronize(runtime, updatedLimits: (Self.bob.accountIdHex, edited))
        }

        let earlierBegun = runtime.begun.count, earlierGrants = runtime.grants.count

        try await bridge.synchronize(runtime)

        let begun = runtime.begun.dropFirst(earlierBegun).first { $0.account == Self.alice.accountIdHex }
        let grants = runtime.grants.dropFirst(earlierGrants)
        #expect(grants.map(\.account) == [Self.alice.accountIdHex])
        #expect(grants.first?.generation == begun?.generation)
        #expect(begun != nil)
    }

    /// One applied grant is reported even when a later account's grant isn't.
    @Test func anAppliedGrantIsReportedEvenIfALaterOneIsNot() async throws {
        let runtime = FakeAttachmentRuntime(accounts: [Self.alice, Self.bob], rejectedGrants: [Self.bob.accountIdHex])
        let permissions = FakePermissionSource()
        let bridge = AttachmentPolicyBridge(permissions: { permissions })

        try await bridge.synchronize(runtime)

        #expect(runtime.grants.count == 2)
        #expect(permissions.appliedCount == 1)
    }

    /// Each event grants the preference as it is when the event runs.
    @Test func aLaterEventGrantsTheChangedPermission() async throws {
        let runtime = FakeAttachmentRuntime(accounts: [Self.alice])
        let permissions = FakePermissionSource()
        let bridge = AttachmentPolicyBridge(permissions: { permissions })
        try await bridge.synchronize(runtime)
        let changed = AttachmentAutomaticPermissionFfi(images: false, videos: false, audio: false, files: false)
        permissions.override = changed

        try await bridge.synchronize(runtime)

        #expect(runtime.grants.map(\.permission).last == changed)
        #expect(runtime.grants.map(\.permission).first != changed)
        #expect(runtime.grants.map(\.generation).last == runtime.begun.map(\.generation).last)
    }

    @Test func anUnchangedPolicyIsNotRewritten() async throws {
        let runtime = FakeAttachmentRuntime(accounts: [Self.alice], stored: attachmentPolicy(automatic: true))
        let bridge = AttachmentPolicyBridge(permissions: { FakePermissionSource() })

        try await bridge.synchronize(runtime)

        #expect(runtime.writes.isEmpty)
        #expect(runtime.grants.count == 1)
    }

    @Test func aGrantTheRuntimeDidNotApplyIsNotReported() async throws {
        let runtime = FakeAttachmentRuntime(accounts: [Self.alice], rejectedGrants: [Self.alice.accountIdHex])
        let permissions = FakePermissionSource()
        let bridge = AttachmentPolicyBridge(permissions: { permissions })

        try await bridge.synchronize(runtime)

        #expect(runtime.grants.count == 1)
        #expect(permissions.appliedCount == 0)
    }

    /// A runtime that doesn't advance transport cursors is never touched and
    /// never adopted: a preference change still resyncs the runtime that was
    /// active before it, with that event's own generation.
    @Test func aPreferenceChangeResyncsTheActiveRuntimeAndNeverAFrozenOne() async throws {
        let active = FakeAttachmentRuntime(accounts: [Self.alice])
        let frozen = FakeAttachmentRuntime(accounts: [Self.alice], cursorPersistence: .frozen)
        let bridge = AttachmentPolicyBridge(permissions: { FakePermissionSource() })
        try await bridge.synchronize(active)
        try await bridge.synchronize(frozen)

        bridge.policyDidChange()

        try await eventually { active.grants.count == 2 }
        #expect(active.grants.map(\.generation) == active.begun.map(\.generation))
        #expect(frozen.listings == 0)
    }

    @Test func policyDidChangeDoesNotFireBeforeStartupCompletes() async throws {
        let runtime = FakeAttachmentRuntime(accounts: [Self.alice], stored: attachmentPolicy(automatic: false))
        let permissions = FakePermissionSource()
        let bridge = AttachmentPolicyBridge(permissions: { permissions })
        let hold = runtime.hold(.listing)

        let startup = Task { @MainActor in
            try await bridge.synchronize(runtime, beforeStart: true)
        }
        try await hold.entered.wait()

        // NWPathMonitor firing while beforeStart is running must not schedule a
        // post-start permission grant against an unstarted runtime.
        bridge.policyDidChange()
        hold.release.signal()
        try await startup.value

        // Even after beforeStart returns (while marmot.start() is still in
        // flight), policyDidChange must remain silent until post-start sync.
        let listingsAfterBeforeStart = runtime.listings
        bridge.policyDidChange()
        await Task.yield()

        #expect(runtime.listings == listingsAfterBeforeStart)
        #expect(runtime.grants.isEmpty)
        #expect(permissions.appliedCount == 0)

        // Once post-start synchronize completes, policyDidChange activates.
        try await bridge.synchronize(runtime)
        #expect(runtime.grants.count == 1)

        bridge.policyDidChange()
        try await eventually { runtime.grants.count == 2 }
    }

    @Test func detachPreventsPolicyDidChangeAndCancelsInFlightWork() async throws {
        let runtime = FakeAttachmentRuntime(accounts: [Self.alice], stored: attachmentPolicy(automatic: true))
        let permissions = FakePermissionSource()
        let bridge = AttachmentPolicyBridge(permissions: { permissions })
        try await bridge.synchronize(runtime)
        #expect(runtime.grants.count == 1)
        #expect(runtime.writes.isEmpty)

        let hold = runtime.hold(.read)
        let edited = attachmentPolicy(transfer: 8 * mebibyte)
        let save = try await start(bridge, runtime, updatedLimits: (Self.alice.accountIdHex, edited))
        try await hold.entered.wait()

        let drained = bridge.detach(client: runtime)
        hold.release.signal()

        await #expect(throws: CancellationError.self) { try await save.value }
        _ = try? await drained?.value
        #expect(runtime.writes.isEmpty)
        #expect(runtime.grants.count == 1)

        let listingsAfterDetach = runtime.listings
        bridge.policyDidChange()
        await Task.yield()

        #expect(runtime.listings == listingsAfterDetach)
        #expect(runtime.grants.count == 1)
    }

    @Test func detachStopsEarlierQueuedRevocationsFromCallingDetachedClient() async throws {
        let runtime = FakeAttachmentRuntime(accounts: [Self.alice], stored: attachmentPolicy(automatic: true))
        let bridge = AttachmentPolicyBridge(permissions: { FakePermissionSource() })
        let hold = runtime.hold(.listing)

        let first = try await start(bridge, runtime)
        try await hold.entered.wait()
        let second = try await start(bridge, runtime)
        let third = try await start(bridge, runtime)

        let drained = bridge.detach(client: runtime)
        hold.release.signal()

        await #expect(throws: CancellationError.self) { try await first.value }
        await #expect(throws: CancellationError.self) { try await second.value }
        await #expect(throws: CancellationError.self) { try await third.value }
        _ = try? await drained?.value

        // Only `first`'s already-started listAccounts ran; detach stopped
        // `first`'s revocation loop and prevented `second` and `third` from
        // touching the detached runtime at all.
        #expect(runtime.listings == 1)
        #expect(runtime.begun.isEmpty)
        #expect(runtime.reads.isEmpty)
        #expect(runtime.writes.isEmpty)
        #expect(runtime.grants.isEmpty)
    }

    @Test func isAttachedTracksPostStartSyncAndDetach() async throws {
        let runtime = FakeAttachmentRuntime(accounts: [Self.alice], stored: attachmentPolicy(automatic: false))
        let other = FakeAttachmentRuntime(accounts: [Self.alice])
        let frozen = FakeAttachmentRuntime(accounts: [Self.alice], cursorPersistence: .frozen)
        let bridge = AttachmentPolicyBridge(permissions: { FakePermissionSource() })

        #expect(!bridge.isAttached(to: runtime))

        try await bridge.synchronize(runtime, beforeStart: true)
        #expect(!bridge.isAttached(to: runtime))

        try await bridge.synchronize(runtime)
        #expect(bridge.isAttached(to: runtime))
        #expect(!bridge.isAttached(to: other))
        #expect(!bridge.isAttached(to: frozen))

        try await bridge.synchronize(frozen)
        #expect(bridge.isAttached(to: runtime))
        #expect(!bridge.isAttached(to: frozen))

        let drained = bridge.detach(client: runtime)
        _ = try? await drained?.value
        #expect(!bridge.isAttached(to: runtime))

        runtime.failingRevocation = [Self.alice.accountIdHex]
        await #expect(throws: FakeAttachmentRuntime.RevocationFailed.self) {
            try await bridge.synchronize(runtime)
        }
        // A failed post-start sync must NOT mark the runtime attached so the
        // next activation retries reconciliation.
        #expect(!bridge.isAttached(to: runtime))

        runtime.failingRevocation = []
        try await bridge.synchronize(runtime)
        #expect(bridge.isAttached(to: runtime))
    }

    @Test func supersededSyncDoesNotMarkAttachedWhenSupersedingPolicyChangeFailsAfterRevocation() async throws {
        let runtime = FakeAttachmentRuntime(accounts: [Self.alice], stored: attachmentPolicy(automatic: false))
        let bridge = AttachmentPolicyBridge(permissions: { FakePermissionSource() })
        let hold = runtime.hold(.read)

        // Start initial post-start sync and pause during its policy read.
        let initialSync = try await start(bridge, runtime)
        try await hold.entered.wait()

        // A network/preference change supersedes the initial sync, revokes
        // permissions, and then fails during its own policy read.
        runtime.failingRead = [Self.alice.accountIdHex]
        bridge.policyDidChange()
        try await eventually { runtime.begun.count == 2 }

        hold.release.signal()
        try await initialSync.value
        try await eventually { runtime.reads.count == 2 }

        // The superseded initial sync must NOT have marked `runtime` reconciled,
        // so the next foreground activation retries reconciliation.
        #expect(!bridge.isAttached(to: runtime))
        #expect(runtime.grants.isEmpty)

        runtime.failingRead = []
        try await bridge.synchronize(runtime)
        #expect(bridge.isAttached(to: runtime))
        #expect(runtime.grants.count == 1)
    }

    @Test func incompletePolicyPassLeavesRuntimeUnreconciledWhileSkippingUnreadyOnboarding() async throws {
        // 1. An unreadable onboarding checkpoint leaves the runtime unreconciled
        //    so the next foreground activation retries.
        let unreadable = FakeAttachmentRuntime(
            accounts: [Self.alice, Self.erin],
            checkpoints: [Self.erin.accountIdHex: .unreadable]
        )
        let unreadableBridge = AttachmentPolicyBridge(permissions: { FakePermissionSource() })
        try await unreadableBridge.synchronize(unreadable)
        #expect(!unreadableBridge.isAttached(to: unreadable))

        // 2. A rejected automatic-permission grant also leaves the runtime unreconciled.
        let rejected = FakeAttachmentRuntime(
            accounts: [Self.alice],
            rejectedGrants: [Self.alice.accountIdHex]
        )
        let rejectedBridge = AttachmentPolicyBridge(permissions: { FakePermissionSource() })
        try await rejectedBridge.synchronize(rejected)
        #expect(!rejectedBridge.isAttached(to: rejected))

        // 3. An intentionally skipped unready onboarding checkpoint still counts
        //    as reconciled when every eligible account succeeds.
        let unready = FakeAttachmentRuntime(
            accounts: [Self.alice, Self.bob],
            checkpoints: [Self.bob.accountIdHex: .unready]
        )
        let unreadyBridge = AttachmentPolicyBridge(permissions: { FakePermissionSource() })
        try await unreadyBridge.synchronize(unready)
        #expect(unreadyBridge.isAttached(to: unready))
    }

    /// Starts `synchronize` and returns once it has scheduled its event. The
    /// bridge schedules synchronously on entry, in the same main-actor job as
    /// the signal, before its first suspension.
    private func start(
        _ bridge: AttachmentPolicyBridge, _ runtime: FakeAttachmentRuntime,
        beforeStart: Bool = false,
        updatedLimits: (account: String, policy: AttachmentDownloadPolicyFfi)? = nil
    ) async throws -> Task<Void, any Error> {
        let scheduled = TestLatch()
        let task = Task { @MainActor in
            scheduled.signal()
            try await bridge.synchronize(runtime, beforeStart: beforeStart, updatedLimits: updatedLimits)
        }
        try await scheduled.wait()
        return task
    }
}

@MainActor
struct AttachmentPolicyBridgeRuntimeStartupTests {
    @Test(.marmotRuntimeConcurrencyLimit, .closesTestRuntimes, arguments: [false, true])
    func startupRebuildAndFreshRuntimeUseTheOwnersBridge(customFactory: Bool) async throws {
        let initial = try TestRuntimeScope.own(MarmotClient.testClient(), ownsRoot: true)
        let bridge = AttachmentPolicyBridge(permissions: { FakePermissionSource() })
        let factory: RuntimeLifecycle.RuntimeClientFactory
        if customFactory {
            factory = { rootPath, relayUrls, cursorPersistence, telemetryConfig in
                try MarmotClient(rootPath: rootPath, relayUrls: relayUrls, cursorPersistence: cursorPersistence,
                                 telemetryConfig: telemetryConfig, attachmentPolicyBridge: AttachmentPolicyBridge())
            }
        } else {
            factory = RuntimeLifecycle.defaultRuntimeClientFactory
        }
        let state = try TestRuntimeScope.own(AppState.test(
            client: initial, attachmentPolicyBridge: bridge, runtimeClientFactory: factory
        ))
        state.setAppSceneActive(true)
        await state.bootstrap()
        #expect(state.isCurrentClientStarted)

        // A before-start pass leaves a drainable tail on the owner's bridge,
        // even with no accounts. This catches startup using another bridge.
        let initialTail = try #require(bridge.detach(client: initial))
        try await initialTail.value
        try await state.synchronizeAutomaticAttachmentPolicyIfAllowed()
        #expect(bridge.isAttached(to: initial))

        await state.startRuntimeSuspension().value
        #expect(!bridge.isAttached(to: initial))
        await state.startForegroundActivation().value
        let restored = try #require(state.client)
        #expect(state.isCurrentClientStarted)
        let restoredTail = try #require(bridge.detach(client: restored))
        try await restoredTail.value
        try await state.synchronizeAutomaticAttachmentPolicyIfAllowed()
        #expect(bridge.isAttached(to: restored))

        await state.startRuntimeSuspension().value
        #expect(!bridge.isAttached(to: restored))
        let fresh = try TestRuntimeScope.own(restored.freshRuntime())
        try await fresh.startRuntime()
        let freshTail = try #require(bridge.detach(client: fresh))
        try await freshTail.value
    }

    @Test(.marmotRuntimeConcurrencyLimit)
    func isCurrentClientStartedStaysFalseUntilRuntimeStartupCompletes() async throws {
        try await withTestClient { initialClient in
            let startEntered = TestLatch()
            let startRelease = TestLatch()
            let appState = AppState.test(
                client: initialClient,
                runtimeStarter: { client in
                    startEntered.signal()
                    try await startRelease.wait()
                    try await client.startRuntime()
                }
            )
            appState.setAppSceneActive(true)
            #expect(appState.canUseLiveRuntime)
            #expect(!appState.isCurrentClientStarted)

            let bootstrapTask = Task { @MainActor in
                await appState.bootstrap()
            }
            try await startEntered.wait()

            // `client` is assigned and `canUseLiveRuntime` is true, but startup
            // is still running `beforeStart` / `marmot.start()`. The root policy
            // sync task must stay gated until `runtimeStarter` finishes.
            #expect(appState.canUseLiveRuntime)
            #expect(!appState.isCurrentClientStarted)

            startRelease.signal()
            await bootstrapTask.value
            #expect(appState.canUseLiveRuntime && appState.isCurrentClientStarted)

            await appState.startRuntimeSuspension().value
            #expect(!appState.canUseLiveRuntime)
            #expect(!appState.isCurrentClientStarted)
        }
    }
}

/// Models the order of runtime calls, not MDK's own rules: a grant is
/// accepted whatever its generation, so tests assert on the generations the
/// bridge forwards rather than on what MDK would reject.
@MainActor
private final class FakeAttachmentRuntime: AttachmentPolicyRuntime {
    enum Step { case listing, read, write, grant }
    enum Checkpoint { case unready, ready, unreadable, cancelled }
    struct Hold { let entered = TestLatch(); let release = TestLatch() }
    struct Begun { let account: String; let generation: String }
    struct Write { let account: String; let policy: AttachmentDownloadPolicyFfi }
    struct Grant { let account: String; let generation: String; let permission: AttachmentAutomaticPermissionFfi }
    struct Unreadable: Error {}
    struct RevocationFailed: Error {}
    struct ReadFailed: Error {}

    let cursorPersistence: CursorPersistenceFfi
    private let accounts: [AccountSummaryFfi]
    private let checkpoints: [String: Checkpoint]
    private let signedOutDuringRevocation: Set<String>
    var failingRevocation: Set<String>
    var failingRead: Set<String> = []
    private let rejectedGrants: Set<String>
    private var stored: [String: AttachmentDownloadPolicyFfi]
    private var holds: [Step: Hold] = [:]
    private var issued = 0
    private(set) var listings = 0
    private(set) var reads: [String] = []
    private(set) var begun: [Begun] = []
    private(set) var writes: [Write] = []
    private(set) var grants: [Grant] = []

    init(accounts: [AccountSummaryFfi], stored: AttachmentDownloadPolicyFfi = attachmentPolicy(),
         checkpoints: [String: Checkpoint] = [:], signedOutDuringRevocation: Set<String> = [],
         failingRevocation: Set<String> = [],
         rejectedGrants: Set<String> = [], cursorPersistence: CursorPersistenceFfi = .advance) {
        self.accounts = accounts
        self.stored = Dictionary(uniqueKeysWithValues: accounts.map { ($0.accountIdHex, stored) })
        self.checkpoints = checkpoints
        self.signedOutDuringRevocation = signedOutDuringRevocation
        self.failingRevocation = failingRevocation
        self.rejectedGrants = rejectedGrants
        self.cursorPersistence = cursorPersistence
    }

    func storedPolicy(_ account: String) throws -> AttachmentDownloadPolicyFfi {
        try #require(stored[account])
    }

    /// The generation the second event began, for tests that run two events.
    func secondGeneration() throws -> String {
        try #require(begun.count == 2)
        return begun[1].generation
    }

    /// Parks the next call of `step` until `release` is signalled; `entered`
    /// opens once it is parked. A held write or grant is recorded when it ends.
    func hold(_ step: Step) -> Hold {
        let hold = Hold()
        holds[step] = hold
        return hold
    }

    private func pass(_ step: Step) async throws {
        guard let hold = holds.removeValue(forKey: step) else { return }
        hold.entered.signal()
        try await hold.release.wait()
    }

    func listAccounts() async throws -> [AccountSummaryFfi] {
        listings += 1
        try await pass(.listing)
        return accounts
    }

    func onboardingSnapshot(accountID: String) async throws -> OnboardingSnapshotFfi? {
        let ready: Bool
        switch checkpoints[accountID] {
        case nil: return nil
        case .unreadable: throw Unreadable()
        case .cancelled: throw CancellationError()
        case .unready: ready = false
        case .ready: ready = true
        }
        return onboardingCheckpoint(accountID: accountID, ready: ready)
    }

    func beginAttachmentPermissionUpdate(accountRef: String) async throws -> String {
        if signedOutDuringRevocation.contains(accountRef) { throw MarmotKitError.AttachmentAccountSignedOut }
        if failingRevocation.contains(accountRef) { throw RevocationFailed() }
        issued += 1
        let generation = "generation-\(issued)"
        begun.append(Begun(account: accountRef, generation: generation))
        return generation
    }

    func attachmentDownloadPolicy(accountRef: String) async throws -> AttachmentDownloadPolicyFfi {
        reads.append(accountRef)
        if failingRead.contains(accountRef) { throw ReadFailed() }
        let policy = try #require(stored[accountRef])
        try await pass(.read)
        return policy
    }

    func setAttachmentDownloadPolicy(accountRef: String, policy: AttachmentDownloadPolicyFfi) async throws {
        try await pass(.write)
        writes.append(Write(account: accountRef, policy: policy))
        stored[accountRef] = policy
    }

    func setAttachmentAutomaticPermission(accountRef: String, generation: String,
                                          permission: AttachmentAutomaticPermissionFfi) async throws -> Bool {
        try await pass(.grant)
        grants.append(Grant(account: accountRef, generation: generation, permission: permission))
        return !rejectedGrants.contains(accountRef)
    }
}

@MainActor
private final class FakePermissionSource: AttachmentPermissionSource {
    private(set) var appliedCount = 0
    /// When set, every account gets this permission.
    var override: AttachmentAutomaticPermissionFfi?

    /// Differs per account, so a permission forwarded to the wrong account shows.
    func attachmentPermission(accountID: String) -> AttachmentAutomaticPermissionFfi {
        if let override { return override }
        let images = accountID.hasPrefix("a")
        return AttachmentAutomaticPermissionFfi(images: images, videos: !images, audio: true, files: false)
    }

    func didApplyAttachmentPermission() {
        appliedCount += 1
    }
}
