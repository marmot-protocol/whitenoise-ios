import Testing
import MarmotKit
@testable import whitenoise_ios

/// The decisions `AttachmentPolicyBridge.synchronize` makes for each account:
/// the policy it writes, and the per-event rules for unready accounts,
/// superseded events, granting and the save result. How `synchronize` wires
/// them is in `AttachmentPolicyBridgeWiringTests`.
struct AttachmentPolicyBridgeTests {
    private static let alice = AccountSummaryFfi(label: "alice", accountIdHex: hex("aa"), localSigning: true,
                                                 signedOut: false, running: true)
    /// Customised limits, so preserving them can't be confused with resetting to defaults.
    private static let stored = attachmentPolicy(automatic: false, retained: 3_000 * mebibyte,
                                                 reserve: 700 * mebibyte, transfer: 90 * mebibyte)

    @Test func automaticIsAlwaysOnBecauseTheRuntimePermissionOwnsNetworkAccess() {
        let update = AttachmentPolicyBridge.policy(Self.stored, for: Self.alice, applying: nil)

        #expect(update.policy.automatic)
        #expect(!update.appliesLimits)
        // Only the legacy flag changes when no limits were edited.
        var expected = Self.stored
        expected.automatic = true
        #expect(update.policy == expected)
    }

    @Test(arguments: [hex("aa"), "alice"])
    func editedLimitsApplyToTheAccountTheyName(_ name: String) {
        let edited = attachmentPolicy(automatic: false, retained: 1_024 * mebibyte, reserve: 128 * mebibyte,
                                      transfer: 32 * mebibyte)
        let update = AttachmentPolicyBridge.policy(Self.stored, for: Self.alice,
                                                   applying: (account: name, policy: edited))

        #expect(update.appliesLimits)
        #expect(update.policy.retainedBytes == edited.retainedBytes)
        #expect(update.policy.diskReserve == edited.diskReserve)
        #expect(update.policy.transferLimit == edited.transferLimit)
        // The edited policy's own `automatic` never turns the legacy flag off.
        #expect(update.policy.automatic)
    }

    /// Saving limits that are already stored still counts as applied; otherwise
    /// `synchronize` would report the save as unavailable.
    @Test func editedLimitsEqualToTheStoredOnesStillApply() {
        var stored = Self.stored
        stored.automatic = true
        let update = AttachmentPolicyBridge.policy(stored, for: Self.alice,
                                                   applying: (account: "alice", policy: stored))

        #expect(update.appliesLimits)
        #expect(update.policy == stored)
    }

    @Test func editedLimitsLeaveOtherAccountsAlone() {
        let current = Self.stored
        let edited = attachmentPolicy(retained: 2_048 * mebibyte, reserve: 0, transfer: 1_024 * mebibyte)
        let update = AttachmentPolicyBridge.policy(current, for: Self.alice,
                                                   applying: (account: hex("bb"), policy: edited))

        #expect(!update.appliesLimits)
        #expect(update.policy.retainedBytes == current.retainedBytes)
        #expect(update.policy.diskReserve == current.diskReserve)
        #expect(update.policy.transferLimit == current.transferLimit)
        #expect(update.policy.automatic)
    }
}

extension AttachmentPolicyBridgeTests {
    @Test func accountsStillInOnboardingKeepTheirPolicy() {
        #expect(!AttachmentPolicyBridge.configures(onboardingReady: false))
        #expect(AttachmentPolicyBridge.configures(onboardingReady: true))
        // An account without an onboarding checkpoint is configured.
        #expect(AttachmentPolicyBridge.configures(onboardingReady: nil))
    }

    /// Settings must never report a superseded save as saved; a background
    /// resync that a newer event replaced just stops.
    @Test func aSupersededSaveFailsButASupersededResyncStopsQuietly() {
        #expect(throws: CancellationError.self) {
            try AttachmentPolicyBridge.endSupersededEvent(limitsEdited: true)
        }
        #expect(throws: Never.self) {
            try AttachmentPolicyBridge.endSupersededEvent(limitsEdited: false)
        }
    }

    @Test func onlyTheCurrentEventAfterStartupGrantsThePermission() {
        #expect(AttachmentPolicyBridge.grantsPermission(beforeStart: false, isCurrentEvent: true))
        // An event that is no longer current never grants its stale generation.
        #expect(!AttachmentPolicyBridge.grantsPermission(beforeStart: false, isCurrentEvent: false))
        // A sync before startup writes policy only.
        #expect(!AttachmentPolicyBridge.grantsPermission(beforeStart: true, isCurrentEvent: true))
        #expect(!AttachmentPolicyBridge.grantsPermission(beforeStart: true, isCurrentEvent: false))
    }

    @Test func editedLimitsThatMatchedNoAccountReportTheSaveAsUnavailable() {
        #expect(throws: AttachmentReadError.unavailable) {
            try AttachmentPolicyBridge.finishEvent(limitsEdited: true, appliedLimits: false)
        }
        #expect(throws: Never.self) {
            try AttachmentPolicyBridge.finishEvent(limitsEdited: true, appliedLimits: true)
        }
        // A resync without edited limits has nothing to apply and still succeeds.
        #expect(throws: Never.self) {
            try AttachmentPolicyBridge.finishEvent(limitsEdited: false, appliedLimits: false)
        }
    }
}

/// How `synchronize` wires those decisions against a runtime: revoking in event
/// order, forwarding only the generation it began, and stopping events that a
/// newer one or a replaced client superseded.
@MainActor
struct AttachmentPolicyBridgeWiringTests {
    private static let alice = AccountSummaryFfi(label: "alice", accountIdHex: hex("aa"), localSigning: true,
                                                 signedOut: false, running: true)
    private static let bob = AccountSummaryFfi(label: "bob", accountIdHex: hex("bb"), localSigning: true,
                                               signedOut: false, running: true)
    private static let carol = AccountSummaryFfi(label: "carol", accountIdHex: hex("cc"), localSigning: true,
                                                 signedOut: true, running: false)

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

    @Test func aNewerEventRevokesOnlyAfterTheEarlierRevocationAndTheEarlierEventGrantsNothing() async throws {
        let runtime = FakeAttachmentRuntime(accounts: [Self.alice])
        let bridge = AttachmentPolicyBridge(permissions: { FakePermissionSource() })
        let (entered, release) = runtime.holdNextListing()

        let first = Task { try await bridge.synchronize(runtime) }
        try await entered.wait()
        let second = Task { try await bridge.synchronize(runtime) }
        // Give a newer revocation that didn't wait the turns to run ahead; it
        // would begin first and the assertions below would see its generation.
        for _ in 0..<20 { await Task.yield() }
        #expect(runtime.listings == 1)
        #expect(runtime.begun.isEmpty)
        release.signal()
        try await first.value
        try await second.value

        #expect(runtime.begun.map(\.generation) == ["\(Self.alice.accountIdHex)#1", "\(Self.alice.accountIdHex)#2"])
        // Only the current event grants, and only its own generation.
        #expect(runtime.grants.map(\.generation) == ["\(Self.alice.accountIdHex)#2"])
    }

    @Test func aReplacedClientsEventStopsAndItsSaveFails() async throws {
        let old = FakeAttachmentRuntime(accounts: [Self.alice])
        let new = FakeAttachmentRuntime(accounts: [Self.alice])
        let bridge = AttachmentPolicyBridge(permissions: { FakePermissionSource() })
        let (entered, release) = old.holdNextListing()
        let limits = (account: Self.alice.accountIdHex, policy: attachmentPolicy(transfer: 8 * mebibyte))

        let save = Task { try await bridge.synchronize(old, updatedLimits: limits) }
        try await entered.wait()
        let resync = Task { try await bridge.synchronize(new) }
        release.signal()

        await #expect(throws: CancellationError.self) { try await save.value }
        try await resync.value
        #expect(old.writes.isEmpty)
        #expect(old.grants.isEmpty)
        #expect(new.grants.map(\.account) == [Self.alice.accountIdHex])
    }

    @Test func aStartupSyncWritesThePolicyButGrantsNothing() async throws {
        let runtime = FakeAttachmentRuntime(accounts: [Self.alice], stored: attachmentPolicy(automatic: false))
        let permissions = FakePermissionSource()
        let bridge = AttachmentPolicyBridge(permissions: { permissions })

        try await bridge.synchronize(runtime, beforeStart: true)

        #expect(runtime.writes.map(\.policy.automatic) == [true])
        #expect(runtime.grants.isEmpty)
        #expect(permissions.appliedCount == 0)
    }

    @Test func accountsInOnboardingAreRevokedButNeitherConfiguredNorGranted() async throws {
        let runtime = FakeAttachmentRuntime(accounts: [Self.alice, Self.bob], stored: attachmentPolicy(automatic: false),
                                            unready: [Self.bob.accountIdHex])
        let bridge = AttachmentPolicyBridge(permissions: { FakePermissionSource() })

        try await bridge.synchronize(runtime)

        #expect(runtime.begun.map(\.account) == [Self.alice.accountIdHex, Self.bob.accountIdHex])
        #expect(runtime.writes.map(\.account) == [Self.alice.accountIdHex])
        #expect(runtime.grants.map(\.account) == [Self.alice.accountIdHex])
    }

    @Test func signedOutAccountsAreSkippedWithoutFailingTheEvent() async throws {
        let runtime = FakeAttachmentRuntime(accounts: [Self.carol, Self.alice, Self.bob],
                                            signedOutDuringRevocation: [Self.alice.accountIdHex])
        let bridge = AttachmentPolicyBridge(permissions: { FakePermissionSource() })

        try await bridge.synchronize(runtime)

        #expect(runtime.begun.map(\.account) == [Self.bob.accountIdHex])
        #expect(runtime.grants.map(\.account) == [Self.bob.accountIdHex])
    }

    @Test func anUnchangedPolicyIsNotRewritten() async throws {
        let runtime = FakeAttachmentRuntime(accounts: [Self.alice], stored: attachmentPolicy(automatic: true))
        let bridge = AttachmentPolicyBridge(permissions: { FakePermissionSource() })

        try await bridge.synchronize(runtime)

        #expect(runtime.writes.isEmpty)
        #expect(runtime.grants.count == 1)
    }

    @Test func aGrantTheRuntimeDidNotApplyIsNotReported() async throws {
        let runtime = FakeAttachmentRuntime(accounts: [Self.alice], appliesGrants: false)
        let permissions = FakePermissionSource()
        let bridge = AttachmentPolicyBridge(permissions: { permissions })

        try await bridge.synchronize(runtime)

        #expect(runtime.grants.count == 1)
        #expect(permissions.appliedCount == 0)
    }

    /// A runtime that doesn't advance transport cursors is never touched, and
    /// later preference changes don't adopt it.
    @Test func aFrozenRuntimeIsLeftAlone() async throws {
        let runtime = FakeAttachmentRuntime(accounts: [Self.alice], cursorPersistence: .frozen)
        let bridge = AttachmentPolicyBridge(permissions: { FakePermissionSource() })

        try await bridge.synchronize(runtime)
        bridge.policyDidChange()
        for _ in 0..<20 { await Task.yield() }

        #expect(runtime.listings == 0)
    }

    @Test func aPreferenceChangeResyncsTheActiveClient() async throws {
        let runtime = FakeAttachmentRuntime(accounts: [Self.alice])
        let bridge = AttachmentPolicyBridge(permissions: { FakePermissionSource() })
        try await bridge.synchronize(runtime)

        bridge.policyDidChange()

        try await eventually { runtime.grants.count == 2 }
        #expect(runtime.grants.map(\.generation) == runtime.begun.map(\.generation))
    }
}

@MainActor
private final class FakeAttachmentRuntime: AttachmentPolicyRuntime {
    struct Begun { let account: String; let generation: String }
    struct Write { let account: String; let policy: AttachmentDownloadPolicyFfi }
    struct Grant { let account: String; let generation: String; let permission: AttachmentAutomaticPermissionFfi }

    let cursorPersistence: CursorPersistenceFfi
    private let accounts: [AccountSummaryFfi]
    private let unready: Set<String>
    private let signedOutDuringRevocation: Set<String>
    private let appliesGrants: Bool
    private var stored: [String: AttachmentDownloadPolicyFfi]
    private var heldListing: (entered: TestLatch, release: TestLatch)?
    private(set) var listings = 0
    private(set) var begun: [Begun] = []
    private(set) var writes: [Write] = []
    private(set) var grants: [Grant] = []

    init(accounts: [AccountSummaryFfi], stored: AttachmentDownloadPolicyFfi = attachmentPolicy(),
         unready: Set<String> = [], signedOutDuringRevocation: Set<String> = [], appliesGrants: Bool = true,
         cursorPersistence: CursorPersistenceFfi = .advance) {
        self.accounts = accounts
        self.stored = Dictionary(uniqueKeysWithValues: accounts.map { ($0.accountIdHex, stored) })
        self.unready = unready
        self.signedOutDuringRevocation = signedOutDuringRevocation
        self.appliesGrants = appliesGrants
        self.cursorPersistence = cursorPersistence
    }

    /// Parks the next `listAccounts` until `release` is signalled; `entered`
    /// opens once it is parked.
    func holdNextListing() -> (entered: TestLatch, release: TestLatch) {
        let hold = (entered: TestLatch(), release: TestLatch())
        heldListing = hold
        return hold
    }

    func listAccounts() async throws -> [AccountSummaryFfi] {
        listings += 1
        if let hold = heldListing {
            heldListing = nil
            hold.entered.signal()
            try await hold.release.wait()
        }
        return accounts
    }

    func onboardingSnapshot(accountID: String) async throws -> OnboardingSnapshotFfi? {
        guard unready.contains(accountID) else { return nil }
        return OnboardingSnapshotFfi(accountIdHex: accountID, recoveryEpoch: nil, revision: 1, ready: false, steps: [],
                                     proposal: nil, singleDeviceNotice: nil, cancellationPending: false)
    }

    func beginAttachmentPermissionUpdate(accountRef: String) async throws -> String {
        if signedOutDuringRevocation.contains(accountRef) { throw MarmotKitError.AttachmentAccountSignedOut }
        let generation = "\(accountRef)#\(begun.count(where: { $0.account == accountRef }) + 1)"
        begun.append(Begun(account: accountRef, generation: generation))
        return generation
    }

    func attachmentDownloadPolicy(accountRef: String) async throws -> AttachmentDownloadPolicyFfi {
        try #require(stored[accountRef])
    }

    func setAttachmentDownloadPolicy(accountRef: String, policy: AttachmentDownloadPolicyFfi) async throws {
        writes.append(Write(account: accountRef, policy: policy))
        stored[accountRef] = policy
    }

    func setAttachmentAutomaticPermission(accountRef: String, generation: String,
                                          permission: AttachmentAutomaticPermissionFfi) async throws -> Bool {
        grants.append(Grant(account: accountRef, generation: generation, permission: permission))
        return appliesGrants
    }
}

@MainActor
private final class FakePermissionSource: AttachmentPermissionSource {
    private(set) var appliedCount = 0

    /// Differs per account, so a permission forwarded to the wrong account shows.
    func attachmentPermission(accountID: String) -> AttachmentAutomaticPermissionFfi {
        let images = accountID.hasPrefix("a")
        return AttachmentAutomaticPermissionFfi(images: images, videos: !images, audio: true, files: false)
    }

    func didApplyAttachmentPermission() {
        appliedCount += 1
    }
}
