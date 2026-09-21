import Testing
@testable import whitenoise_ios
@testable import MarmotKit

struct GroupSharedMediaPresentationTests {
    @Test func splitsVisualMediaFromOtherFilesAndSortsNewestFirst() {
        let image = mediaRecord(
            messageID: "image-message",
            index: 0,
            mediaType: "image/jpeg",
            fileName: "photo.jpg",
            timestamp: 20
        )
        let video = mediaRecord(
            messageID: "video-message",
            index: 0,
            mediaType: "video/mp4",
            fileName: "clip.mp4",
            timestamp: 30
        )
        let document = mediaRecord(
            messageID: "document-message",
            index: 1,
            mediaType: "application/pdf",
            fileName: "notes.pdf",
            timestamp: 10
        )

        let items = GroupSharedMediaPresentation.items(from: [document, image, video])
        let visual = GroupSharedMediaPresentation.visualItems(from: items)
        let files = SharedMediaLibraryPresentation.fileItems(from: items)

        #expect(items.map(\.attachment.fileName) == ["clip.mp4", "photo.jpg", "notes.pdf"])
        #expect(visual.map(\.attachment.fileName) == ["clip.mp4", "photo.jpg"])
        #expect(files.map(\.attachment.fileName) == ["notes.pdf"])
    }

    @Test func attachmentIdentityIncludesOwningMessageAndIndex() {
        let first = mediaRecord(
            messageID: "message-a",
            index: 0,
            mediaType: "image/jpeg",
            fileName: "same.jpg",
            timestamp: 10
        )
        let second = mediaRecord(
            messageID: "message-b",
            index: 1,
            mediaType: "image/jpeg",
            fileName: "same.jpg",
            timestamp: 10
        )

        let items = GroupSharedMediaPresentation.items(from: [first, second])

        #expect(Set(items.map(\.id)).count == 2)
        #expect(Set(items.map(\.attachment.id)).count == 2)
    }

    @Test func duplicateRecordsWithoutMessageIDsRemainDistinctAndStable() {
        let record = mediaRecord(
            messageID: "",
            index: 0,
            mediaType: "image/jpeg",
            fileName: "same.jpg",
            timestamp: 10
        )

        let firstProjection = GroupSharedMediaPresentation.items(from: [record, record])
        let secondProjection = GroupSharedMediaPresentation.items(from: [record, record])

        #expect(Set(firstProjection.map(\.id)).count == 2)
        #expect(Set(firstProjection.map(\.attachment.id)).count == 2)
        #expect(firstProjection.map(\.id) == secondProjection.map(\.id))
    }
}

private func mediaRecord(
    messageID: String,
    index: UInt32,
    mediaType: String,
    fileName: String,
    timestamp: UInt64
) -> MediaRecordFfi {
    let hashSeed = String(messageID.utf8.reduce(0) { $0 &+ UInt64($1) }, radix: 16)
    let hash = String(repeating: "0", count: max(0, 64 - hashSeed.count)) + hashSeed
    return MediaRecordFfi(
        messageIdHex: messageID,
        attachmentIndex: index,
        direction: "received",
        groupIdHex: String(repeating: "ab", count: 32),
        sender: String(repeating: "cd", count: 32),
        reference: MediaAttachmentReferenceFfi(
            locators: [MediaLocatorFfi(kind: "blossom-v1", value: "https://example.com/media")],
            ciphertextSha256: String(repeating: "1", count: 64),
            plaintextSha256: hash,
            nonceHex: String(repeating: "2", count: 24),
            fileName: fileName,
            mediaType: mediaType,
            version: .v1,
            sourceEpoch: 1,
            dim: nil,
            thumbhash: nil
        ),
        caption: nil,
        recordedAt: timestamp,
        receivedAt: timestamp
    )
}

extension GroupSharedMediaPresentationTests {
    @Test func nativeHistoryKeepsCanonicalOrderAndOriginalSlots() {
        let reference = mediaRecord(messageID: "message", index: 2, mediaType: "image/jpeg",
                                    fileName: "photo.jpg", timestamp: 1).reference
        let pending = MessageMediaAttachment.displayItems(fromOutcomes: [.accepted(attachmentIndex: 2, reference: reference)],
            ownerId: "pending", messageId: "pending-local-id")
        #expect(pending.first?.localTarget == nil && pending.first?.sourceHint == nil)
        let reply = MessageMediaAttachment.displayItems(fromOutcomes: [.accepted(attachmentIndex: 2, reference: reference)],
            ownerId: "reply", messageId: "original-message", resolveMissingSource: true)
        #expect(reply.first?.sourceHint == AttachmentSourceHint(messageID: "original-message", slot: 2))
        let newest = AttachmentEntryFfi(messageIdHex: "newest", sourceMessageIdHex: "original-source",
            sender: "sender", timelineAt: 1, receivedAt: 90, sourceEpoch: nil, category: .image,
            attachment: .accepted(attachmentIndex: 2, reference: reference))
        let older = AttachmentEntryFfi(messageIdHex: "older", sourceMessageIdHex: "older-source",
            sender: "sender", timelineAt: 50, receivedAt: 2, sourceEpoch: 1, category: .image,
            attachment: .accepted(attachmentIndex: 7, reference: reference))
        let items = GroupSharedMediaPresentation.items(entries: [newest, older])
        #expect(items.map(\.id) == ["newest:2", "older:7"])
        #expect(items.map(\.timestamp) == [1, 50])
        #expect(items[0].attachment.localTarget == AttachmentLocalTargetFfi(
            messageIdHex: "newest", sourceMessageIdHex: "original-source", attachmentIndex: 2))
        var replacement = newest
        replacement.attachment = .accepted(attachmentIndex: 2,
            reference: mediaRecord(messageID: "different-content", index: 2, mediaType: "image/jpeg",
                                   fileName: "updated.jpg", timestamp: 99).reference)
        #expect(GroupSharedMediaPresentation.items(entries: [replacement]).first?.id == items[0].id)
    }
}
