import Foundation
import Testing
@testable import MarmotKit
@testable import whitenoise_ios

/// The timeline skips a bubble's body while its `==` holds, so equality has
/// to follow everything the bubble draws and nothing else.
@MainActor
@Suite struct MessageBubbleEqualityTests {
    private func attachment(target: AttachmentLocalTargetFfi? = nil) -> MessageMediaAttachment {
        MessageMediaAttachment(
            id: "row:0",
            reference: nil,
            fileName: "photo.jpg",
            mediaType: "image/jpeg",
            dim: nil,
            localData: nil,
            localTarget: target
        )
    }

    @Test func freshHandlersDoNotForceARedraw() {
        let record = message(id: hex("01"))
        let first = MessageBubble(record: record, status: .sent, onShowReactionDetails: { _ in },
                                  onReplyPreviewTap: {})
        let second = MessageBubble(record: record, status: .sent, onShowReactionDetails: { _ in },
                                   onReplyPreviewTap: {})
        #expect(first == second)
    }

    @Test func drawnContentChangesRedraw() {
        let record = message(id: hex("01"))
        let base = MessageBubble(record: record, status: .sent)
        #expect(base != MessageBubble(record: message(id: hex("01"), plaintext: "edited"), status: .sent))
        #expect(base != MessageBubble(record: record, status: .failed))
        #expect(base != MessageBubble(record: record, status: .sent, isDeleted: true))
        #expect(base != MessageBubble(record: record, status: .sent, reactions: [
            ConversationViewModel.ReactionTally(emoji: "👍", count: 1, mine: false),
        ]))
    }

    @Test func gainingOrLosingAHandlerRedraws() {
        let record = message(id: hex("01"))
        let plain = MessageBubble(record: record, status: .failed)
        let tappable = MessageBubble(record: record, status: .failed, onFailedTap: {})
        #expect(plain != tappable)
    }

    @Test func attachmentLoadRoutingChangesRedraw() {
        let record = message(id: hex("01"))
        let unresolved = MessageBubble(record: record, status: .sent, mediaItems: [attachment()])
        let resolved = MessageBubble(record: record, status: .sent, mediaItems: [
            attachment(target: AttachmentLocalTargetFfi(messageIdHex: hex("01"), sourceMessageIdHex: hex("01"),
                                                        attachmentIndex: 0)),
        ])
        #expect(unresolved != resolved)
        #expect(unresolved == MessageBubble(record: record, status: .sent, mediaItems: [attachment()]))
    }
}
