import Foundation
import MarmotKit
import Testing
@testable import whitenoise_ios

struct ChatPreviewRetentionTests {
    @Test func finiteExpiryIsInclusiveAndUsesThePinnedExpiry() {
        var preview = sample()
        preview.retentionSeconds = 30
        preview.retentionExpiresAt = 100
        #expect(!ChatPreviewRetention.isExpired(preview, at: Date(timeIntervalSince1970: 99)))
        #expect(ChatPreviewRetention.isExpired(preview, at: Date(timeIntervalSince1970: 100)))
        #expect(ChatPreviewRetention.isExpired(preview, at: Date(timeIntervalSince1970: 101)))
    }

    @Test func unknownDisabledAndOverflowRetainTheirPreview() {
        var preview = sample()
        for duration in [nil, 0, UInt64.max] as [UInt64?] {
            preview.retentionSeconds = duration
            preview.retentionExpiresAt = nil
            #expect(!ChatPreviewRetention.isExpired(preview, at: .distantFuture))
        }
    }

    private func sample() -> ChatListMessagePreviewFfi {
        ChatListMessagePreviewFfi(messageIdHex: "test", sender: "sender", senderDisplayName: nil,
            plaintext: "private preview", kind: 9, timelineAt: 1, deleted: false)
    }
}
