import Testing
import MarmotKit
@testable import whitenoise_ios

/// The per-account policy `AttachmentPolicyBridge.synchronize` writes to MDK.
/// The bridge's other rules (revoking in event order, granting only the
/// captured generation, skipping superseded events and unready accounts) run
/// against a live runtime and have no test yet; see #1228.
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

/// The per-event rules `AttachmentPolicyBridge.synchronize` applies around each
/// account. Revoking in event order and forwarding only the captured generation
/// need a runtime or a fake client and are not covered here.
struct AttachmentPolicyBridgeEventTests {
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
        // A superseded event, or a replaced client, never grants its stale generation.
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
