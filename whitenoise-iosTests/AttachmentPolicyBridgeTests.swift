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
