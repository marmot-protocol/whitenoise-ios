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
        // "Read more" lives with the list; the bubble must redraw when it opens.
        #expect(base != MessageBubble(record: record, status: .sent, isBodyExpanded: true))
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

    @Test func largeAttachmentEqualityAndHashingUseContentTokenWithoutScanningMappedBytes() throws {
        // Above the 64 KiB inline-digest cutoff, payloads receive an O(1) identity token
        // so equality and hashing never scan or fault mapped bytes.
        let payload = Data(repeating: 0x2a, count: 65 * 1024)
        let draftID = UUID()
        let firstDraft = MediaDraftAttachment(
            id: draftID,
            fileName: "large.mov",
            mediaType: "video/quicktime",
            data: payload,
            dim: "1920x1080"
        )
        let distinctDraft = MediaDraftAttachment(
            id: draftID,
            fileName: "large.mov",
            mediaType: "video/quicktime",
            data: Data(repeating: 0x2a, count: 65 * 1024),
            dim: "1920x1080"
        )

        // Identical drafts and derived display/overlay items compare equal in O(1);
        // separately constructed large payloads of identical size remain unequal.
        #expect(firstDraft == firstDraft)
        #expect(Set([firstDraft, firstDraft]).count == 1)
        #expect(firstDraft != distinctDraft)

        let firstDisplay = firstDraft.displayItem
        let secondDisplay = firstDraft.displayItem
        let distinctDisplay = distinctDraft.displayItem
        #expect(firstDisplay == secondDisplay)
        #expect(Set([firstDisplay, secondDisplay]).count == 1)
        #expect(firstDisplay != distinctDisplay)
        #expect(firstDisplay.isSameDocumentSource(as: secondDisplay))
        #expect(!firstDisplay.isSameDocumentSource(as: distinctDisplay))

        // OwnSendMediaStore.overlay preserves the content token across timeline rebuilds.
        let reference = encryptedMediaReference(fileName: "large.mov", mediaType: "video/quicktime", sourceEpoch: 1)
        var store = OwnSendMediaStore()
        store.retain(firstDisplay, plaintextSha256: reference.plaintextSha256)
        var remote = MessageMediaAttachment(
            id: "row:0",
            reference: reference,
            fileName: "large.mov",
            mediaType: "video/quicktime",
            dim: nil,
            localData: nil,
            localTarget: AttachmentLocalTargetFfi(
                messageIdHex: hex("01"),
                sourceMessageIdHex: hex("01"),
                attachmentIndex: 0
            )
        )
        let overlaidA = store.overlay(remote)
        let overlaidB = store.overlay(remote)
        #expect(overlaidA == overlaidB)
        #expect(overlaidA.localDataToken == firstDisplay.localDataToken)
        #expect(overlaidA.forTranscriptPage.localDataToken == nil)
        #expect(overlaidA.forTranscriptPage != overlaidA)

        let record = message(id: hex("01"))
        let bubbleA = MessageBubble(record: record, status: .sent, mediaItems: [overlaidA])
        let bubbleB = MessageBubble(record: record, status: .sent, mediaItems: [overlaidB])
        #expect(bubbleA == bubbleB)

        remote.localTarget = nil
        let bubbleDifferent = MessageBubble(record: record, status: .sent, mediaItems: [distinctDisplay])
        #expect(MessageBubble(record: record, status: .sent, mediaItems: [firstDisplay]) != bubbleDifferent)
    }

    @Test func smallAttachmentEqualityMatchesByContentDigestAndDistinguishesPayloads() {
        let sameID = UUID()
        let first = MediaDraftAttachment(id: sameID, fileName: "note.txt", mediaType: "text/plain", data: Data("same".utf8), dim: nil)
        let reconstructed = MediaDraftAttachment(id: sameID, fileName: "note.txt", mediaType: "text/plain", data: Data("same".utf8), dim: nil)
        let modified = MediaDraftAttachment(id: sameID, fileName: "note.txt", mediaType: "text/plain", data: Data("diff".utf8), dim: nil)

        #expect(first == reconstructed)
        #expect(first.dataToken == reconstructed.dataToken)
        #expect(first != modified)
        #expect(first.displayItem == reconstructed.displayItem)
        #expect(first.displayItem != modified.displayItem)
        #expect(first.displayItem.isSameDocumentSource(as: reconstructed.displayItem))
        #expect(!first.displayItem.isSameDocumentSource(as: modified.displayItem))
    }
}
