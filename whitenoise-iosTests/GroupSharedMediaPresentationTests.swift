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
            sender: "sender", timelineAt: 1, receivedAt: 90, sourceEpoch: nil, category: .image, role: .shared,
            attachment: .accepted(attachmentIndex: 2, reference: reference))
        let older = AttachmentEntryFfi(messageIdHex: "older", sourceMessageIdHex: "older-source",
            sender: "sender", timelineAt: 50, receivedAt: 2, sourceEpoch: 1, category: .image, role: .shared,
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

    @Test func customEmojiArtworkStaysOutOfTheGalleryWithoutStoppingPaging() {
        let reference = mediaRecord(messageID: "message", index: 0, mediaType: "image/png",
                                    fileName: "emoji.png", timestamp: 1).reference
        let emoji = AttachmentEntryFfi(messageIdHex: "emoji-message", sourceMessageIdHex: "emoji-message",
            sender: "sender", timelineAt: 1, receivedAt: 1, sourceEpoch: nil, category: .image, role: .inlineEmoji,
            attachment: .accepted(attachmentIndex: 0, reference: reference))
        var photo = emoji
        photo.messageIdHex = "photo-message"
        photo.role = .shared
        photo.attachment = .accepted(attachmentIndex: 3, reference: reference)

        #expect(GroupSharedMediaPresentation.galleryEntries([emoji, photo]).map(\.messageIdHex) == ["photo-message"])
        // The original slot survives filtering; slots are never renumbered.
        #expect(GroupSharedMediaPresentation.items(entries: [emoji, photo]).map(\.id) == ["photo-message:3"])
        #expect(GroupSharedMediaPresentation.items(entries: [emoji]).isEmpty)

        #expect(GroupSharedMediaPresentation.shouldReadPastFilteredPage(galleryEntryCount: 0, hasMore: true))
        #expect(!GroupSharedMediaPresentation.shouldReadPastFilteredPage(galleryEntryCount: 0, hasMore: false))
        #expect(!GroupSharedMediaPresentation.shouldReadPastFilteredPage(galleryEntryCount: 1, hasMore: true))
    }
}

@MainActor
extension GroupSharedMediaPresentationTests {
    @Test func preparedOwnMediaRemainsUsableAfterPeerConfirmationUntilTheSourceArrives() {
        let store = TimelineStore(appState: nil, groupIdHex: hex("aa"))
        var row = timelineRecord(messageIdHex: hex("ab"), sourceMessageIdHex: .some(nil), direction: "sent", timelineAt: 1)
        func install(_ rows: [TimelineMessageRecordFfi]) {
            store.applyConversationWindowPage(.init(messages: rows, hasMoreBefore: false, hasMoreAfter: false))
        }
        install([row])
        #expect(store.hasUnsourcedOwnMessage(row.messageIdHex))
        row.recipientConfirmed = true
        install([row])
        #expect(store.hasUnsourcedOwnMessage(row.messageIdHex))
        row.sourceMessageIdHex = hex("ac")
        install([row])
        #expect(!store.hasUnsourcedOwnMessage(row.messageIdHex))
        row.sourceMessageIdHex = nil
        row.direction = "received"
        install([row])
        #expect(!store.hasUnsourcedOwnMessage(row.messageIdHex))
        row.direction = "sent"
        row.deleted = true
        install([row])
        #expect(!store.hasUnsourcedOwnMessage(row.messageIdHex))
        row.deleted = false
        install([row])
        #expect(store.hasUnsourcedOwnMessage(row.messageIdHex))
        install([])
        #expect(!store.hasUnsourcedOwnMessage(row.messageIdHex))
    }

    private func entry(_ message: String, slot: UInt32 = 0, mediaType: String = "image/jpeg",
                       role: AttachmentRoleFfi = .shared) -> AttachmentEntryFfi {
        let reference = mediaRecord(messageID: message, index: slot, mediaType: mediaType,
                                    fileName: "sample", timestamp: 10).reference
        return .init(messageIdHex: message, sourceMessageIdHex: "source-" + message, sender: "peer",
            timelineAt: 10, receivedAt: 10, sourceEpoch: nil, category: .image, role: role,
            attachment: .accepted(attachmentIndex: slot, reference: reference))
    }

    @Test func aLoadedContactNameIsSearchableWhenTheFileHasAGenericType() throws {
        let app = AppState.test()
        let viewModel = ConversationViewModel(appState: app, group: group(name: "Chat"))
        let reference = mediaRecord(messageID: "contact", index: 0, mediaType: "application/octet-stream",
                                    fileName: "person.vcf", timestamp: 1).reference
        let record = timelineRecord(messageIdHex: hex("ac"), timelineAt: 1, media: [reference])
        viewModel.applyTimelinePage(.init(messages: [record], hasMoreBefore: false, hasMoreAfter: false), placement: .window)
        let row = try #require(viewModel.timeline.first { $0.id == TimelineItem.messageRowId(forMessageIdHex: record.messageIdHex) })
        let contact = try #require(viewModel.mediaItems(for: row).first)
        viewModel.search.registerContactName("Avery Stone", for: contact.id)
        viewModel.search.activate()
        viewModel.search.query = "Avery"
        #expect(viewModel.search.currentMatch?.messageIdHex == record.messageIdHex)
    }

    @Test func anEmptyWindowKeepsOnlyMediaConnectedToItsSelectedRetainedPage() throws {
        let photo = entry("selected")
        let id = try #require(TranscriptHistorySlot(photo)).attachment.id
        var pages = TranscriptHistoryPages()
        pages.append([entry("newer"), photo])
        #expect(pages.extensions(around: [], excluding: [], preserving: id).older.map(\.target.messageIdHex) == ["selected", "newer"])
        #expect(pages.extensions(around: [], excluding: ["selected"], preserving: id).older.isEmpty)
        #expect(pages.extensions(around: [], excluding: [], preserving: "removed").older.isEmpty)
    }

    @Test func refreshingNewerPhotosKeepsTheSelectedOlderPhotoAcrossPageBoundaries() throws {
        let anchor = entry("visible")
        let window = [try #require(TranscriptHistorySlot(anchor)).attachment]
        var retained = TranscriptHistoryPages()
        retained.append([anchor, entry("selected")])
        var prefix = TranscriptHistoryPages()
        prefix.append([entry("newest")])
        let disjoint = prefix.includingRetainedTail(retained).extensions(around: window, excluding: ["visible"])
        #expect(disjoint.older.map(\.target.messageIdHex) == ["selected"])
        #expect(disjoint.newer.isEmpty)
        prefix.append([entry("next"), anchor])
        let joined = prefix.includingRetainedTail(retained).extensions(around: window, excluding: ["visible"])
        #expect(joined.older.map(\.target.messageIdHex) == ["selected"])
        #expect(joined.newer.map(\.target.messageIdHex) == ["next", "newest"])
    }

    @Test func aHeldGIFConnectsItsWindowToPhotosWithoutAddingOtherGIFs() throws {
        let held = entry("held", mediaType: "image/gif")
        let anchor = try #require(TranscriptHistorySlot(held)).attachment
        var pending = try #require(TranscriptHistorySlot(entry("pending"))).attachment
        pending.localTarget = nil
        var pages = TranscriptHistoryPages()
        pages.append([entry("newer"), entry("another-gif", mediaType: "image/gif")])
        #expect(pages.extensions(around: [anchor], excluding: ["held"]).newer.isEmpty)
        pages.append([held, entry("older")])
        for window in [[anchor], [anchor, pending]] {
            for atTail in [false, true] {
                let edges = pages.extensions(around: window, excluding: ["held"], atLiveTail: atTail)
                #expect(edges.older.map(\.target.messageIdHex) == ["older"])
                #expect(edges.newer.map(\.target.messageIdHex) == ["newer"])
            }
        }
    }

    @Test func waitsForAnExactOverlapBeforeShowingNewerPages() throws {
        let anchor = entry("anchor", slot: 2)
        let window = [try #require(TranscriptHistorySlot(anchor)).attachment]
        var pages = TranscriptHistoryPages()
        var otherSource = anchor
        otherSource.sourceMessageIdHex = "replaced-source"
        pages.append([entry("new"), otherSource, entry("anchor", slot: 1)])
        #expect(pages.extensions(around: window, excluding: ["anchor"]).newer.isEmpty)
        pages.append([anchor, entry("old")])
        let joined = pages.extensions(around: window, excluding: ["anchor"])
        #expect(joined.older.map(\.target.messageIdHex) == ["old"])
        #expect(joined.newer.map(\.target.messageIdHex) == ["new"])
    }

    @Test func joinsSplitAlbumsInOriginalSlotOrderAndSkipsIneligibleRows() throws {
        let anchor = entry("visible")
        let window = [try #require(TranscriptHistorySlot(anchor)).attachment]
        var pages = TranscriptHistoryPages()
        pages.append([anchor, entry("album", slot: 4, mediaType: "video/mp4")])
        pages.append([entry("album", slot: 2, role: .inlineEmoji), entry("album", slot: 1),
                      entry("album", slot: 0, mediaType: "image/gif"), entry("album", slot: 1),
                      entry("hidden-but-loaded"), entry("earlier")])
        let joined = pages.extensions(around: window, excluding: ["visible", "hidden-but-loaded"])
        #expect(joined.older.map(\.target.messageIdHex) == ["earlier", "album", "album"])
        #expect(joined.older.map(\.target.attachmentIndex) == [0, 1, 4])
        #expect(joined.newer.isEmpty)
    }
    @Test @MainActor func locallyHiddenAndBlockedAttachmentsStayOutOfHistory() throws {
        let olderID = String(repeating: "ab", count: 32)
        let slot = try #require(TranscriptHistorySlot(entry(olderID)))
        let store = TimelineStore(appState: nil, groupIdHex: hex("aa"), hiddenMessageIds: [olderID])
        #expect(!slot.isVisible(in: store))
        store.setHiddenMessageIds([])
        store.setBlockedAuthorIds([slot.sender])
        #expect(!slot.isVisible(in: store))
        store.setBlockedAuthorIds([])
        #expect(slot.isVisible(in: store))
    }

    @Test func aReprojectedSlotMustStillReferToTheSameSourceAndBytes() throws {
        let original = entry("photo", slot: 2)
        var pages = TranscriptHistoryPages()
        pages.append([original])
        var row = timelineRecord(messageIdHex: "photo", sourceMessageIdHex: original.sourceMessageIdHex,
                                 sender: original.sender, timelineAt: 10)
        row.media = [original.attachment]
        #expect(!pages.conflicts(with: row))
        row.sourceMessageIdHex = "another-source"
        #expect(pages.conflicts(with: row))
        row.sourceMessageIdHex = original.sourceMessageIdHex
        row.media = [entry("other", slot: 2).attachment]
        #expect(pages.conflicts(with: row))
        row.media = [original.attachment]
        row.deleted = true
        #expect(pages.conflicts(with: row))
    }

    @Test func pendingWindowSlotDoesNotHideAnExactlyLinkedOlderPage() throws {
        let linked = entry("linked")
        let attached = try #require(TranscriptHistorySlot(linked)).attachment
        var pending = attached
        pending.localTarget = nil
        var pages = TranscriptHistoryPages()
        pages.append([linked, entry("earlier")])
        #expect(pages.extensions(around: [pending], excluding: ["linked"]).older.isEmpty)
        #expect(pages.extensions(around: [pending], excluding: ["linked"], atLiveTail: true)
            .older.map(\.target.messageIdHex) == ["earlier"])
        let joined = pages.extensions(around: [pending, attached], excluding: ["linked"])
        #expect(joined.older.map(\.target.messageIdHex) == ["earlier"])
    }
    @Test func newerRetainedHistoryPrecedesOptimisticSends() throws {
        func photo(_ id: String) throws -> MessageMediaAttachment {
            try #require(TranscriptHistorySlot(entry(id))).attachment
        }
        let older = try photo("older"), visible = try photo("visible"), newer = try photo("newer"), pending = try photo("pending")
        let ordered = TranscriptHistoryPages.join(older: [older], window: [visible, pending], newer: [newer],
                                                isOverlay: { $0.id == pending.id })
        #expect(ordered.map(\.id) == [older, visible, newer, pending].map(\.id))
    }
}
