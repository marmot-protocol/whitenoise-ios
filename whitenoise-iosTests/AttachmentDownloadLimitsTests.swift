import Testing
import MarmotKit
@testable import whitenoise_ios

/// Download Storage no longer offers `retainedBytes`, which stopped limiting
/// storage in MarmotKit 0.14.0, but a save must still pass MDK's check that it
/// is at least the automatic download size limit.
struct AttachmentDownloadLimitsTests {
    @Test func savesTheEditedLimitsAndKeepsTheNetworkGate() {
        let next = AttachmentDownloadLimits.applying(diskReserve: 512 * mebibyte,
                                                     transferLimit: 128 * mebibyte,
                                                     to: attachmentPolicy(automatic: false, retained: 2_048 * mebibyte))
        #expect(next == attachmentPolicy(automatic: false, retained: 2_048 * mebibyte, reserve: 512 * mebibyte,
                                     transfer: 128 * mebibyte))
    }

    @Test func raisesTheStoredValueToTheTransferLimitWhenItIsLower() {
        let next = AttachmentDownloadLimits.applying(diskReserve: 0, transferLimit: 512 * mebibyte,
                                                     to: attachmentPolicy(retained: 256 * mebibyte))
        #expect(next.retainedBytes == 512 * mebibyte)
        #expect(next.transferLimit == 512 * mebibyte)
    }
}
