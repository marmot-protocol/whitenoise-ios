import Testing
import MarmotKit
@testable import whitenoise_ios

/// The per-account policy `AttachmentPolicyBridge.synchronize` writes to MDK.
/// The bridge's other rules (revoking in event order, granting only the
/// captured generation, skipping superseded events and unready accounts) run
/// against a live runtime and have no test yet; see #1228.
struct AttachmentPolicyBridgeTests {
    private static let mebibyte: UInt64 = 1_048_576
    private static let alice = AccountSummaryFfi(label: "alice", accountIdHex: hex("aa"), localSigning: true,
                                                 signedOut: false, running: true)

    private static func policy(automatic: Bool = true, retained: UInt64 = 512 * mebibyte,
                               reserve: UInt64 = 256 * mebibyte, transfer: UInt64 = 64 * mebibyte)
        -> AttachmentDownloadPolicyFfi {
        AttachmentDownloadPolicyFfi(automatic: automatic, retainedBytes: retained, diskReserve: reserve,
                                    transferLimit: transfer)
    }

    @Test func automaticIsAlwaysOnBecauseTheRuntimePermissionOwnsNetworkAccess() {
        let update = AttachmentPolicyBridge.policy(Self.policy(automatic: false), for: Self.alice, applying: nil)

        #expect(update.policy.automatic)
        #expect(!update.appliesLimits)
        // Only the legacy flag changes when no limits were edited.
        #expect(update.policy == Self.policy(automatic: true))
    }

    @Test(arguments: [hex("aa"), "alice"])
    func editedLimitsApplyToTheAccountTheyName(_ name: String) {
        let edited = Self.policy(automatic: false, retained: 1_024 * Self.mebibyte, reserve: 128 * Self.mebibyte,
                                 transfer: 32 * Self.mebibyte)
        let update = AttachmentPolicyBridge.policy(Self.policy(), for: Self.alice,
                                                   applying: (account: name, policy: edited))

        #expect(update.appliesLimits)
        #expect(update.policy.retainedBytes == edited.retainedBytes)
        #expect(update.policy.diskReserve == edited.diskReserve)
        #expect(update.policy.transferLimit == edited.transferLimit)
        // The edited policy's own `automatic` never turns the legacy flag off.
        #expect(update.policy.automatic)
    }

    @Test func editedLimitsLeaveOtherAccountsAlone() {
        let current = Self.policy(automatic: false)
        let edited = Self.policy(retained: 2_048 * Self.mebibyte, reserve: 0, transfer: 1_024 * Self.mebibyte)
        let update = AttachmentPolicyBridge.policy(current, for: Self.alice,
                                                   applying: (account: hex("bb"), policy: edited))

        #expect(!update.appliesLimits)
        #expect(update.policy.retainedBytes == current.retainedBytes)
        #expect(update.policy.diskReserve == current.diskReserve)
        #expect(update.policy.transferLimit == current.transferLimit)
        #expect(update.policy.automatic)
    }
}
