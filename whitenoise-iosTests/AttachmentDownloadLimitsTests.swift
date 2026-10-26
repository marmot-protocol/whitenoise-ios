import Testing
import MarmotKit
@testable import whitenoise_ios

/// Download Storage no longer offers `retainedBytes`, which stopped limiting
/// storage in MarmotKit 0.14.0, but a save must still pass MDK's check that it
/// is at least the automatic download size limit.
struct AttachmentDownloadLimitsTests {
    private static let mebibyte: UInt64 = 1_048_576

    private static func policy(automatic: Bool = true, retained: UInt64, reserve: UInt64 = 256 * mebibyte,
                               transfer: UInt64 = 64 * mebibyte) -> AttachmentDownloadPolicyFfi {
        AttachmentDownloadPolicyFfi(automatic: automatic, retainedBytes: retained, diskReserve: reserve,
                                    transferLimit: transfer)
    }

    @Test func savesTheEditedLimitsAndKeepsTheNetworkGate() {
        let next = AttachmentDownloadLimits.applying(diskReserve: 512 * Self.mebibyte,
                                                     transferLimit: 128 * Self.mebibyte,
                                                     to: Self.policy(automatic: false, retained: 2_048 * Self.mebibyte))
        #expect(next == Self.policy(automatic: false, retained: 2_048 * Self.mebibyte, reserve: 512 * Self.mebibyte,
                                    transfer: 128 * Self.mebibyte))
    }

    @Test func raisesTheStoredValueToTheTransferLimitWhenItIsLower() {
        let next = AttachmentDownloadLimits.applying(diskReserve: 0, transferLimit: 512 * Self.mebibyte,
                                                     to: Self.policy(retained: 256 * Self.mebibyte))
        #expect(next.retainedBytes == 512 * Self.mebibyte)
        #expect(next.transferLimit == 512 * Self.mebibyte)
    }
}
