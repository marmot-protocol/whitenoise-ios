import Testing
@testable import whitenoise_ios
@testable import MarmotKit

@MainActor
struct TranscriptAttachmentHistoryTests {
    private func entry(_ message: String, slot: UInt32 = 0, mediaType: String = "image/jpeg",
                       role: AttachmentRoleFfi = .shared) -> AttachmentEntryFfi {
        let reference = encryptedMediaReference(fileName: message, mediaType: mediaType, sourceEpoch: 1)
        return .init(messageIdHex: message, sourceMessageIdHex: "source-" + message, sender: "peer",
            timelineAt: 10, receivedAt: 10, sourceEpoch: nil, category: .image, role: role,
            attachment: .accepted(attachmentIndex: slot, reference: reference))
    }

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

    @Test func aWindowChangeRebuildsRetainedMediaWhenAMessageCrossesTheWindowBoundary() throws {
        var pages = TranscriptHistoryPages()
        pages.append([entry("retained")])
        let gallery = try #require(MessageMediaGallery(transcriptItems: [], openingID: "photo", initialData: nil,
            messages: [:], captions: [:], allowsEmptyWindow: true))
        func window(_ ids: Set<String>) -> TranscriptHistoryGalleryView.Window {
            .init(gallery: gallery, messageIDs: ids, durableIDs: [], atTail: true,
                visibility: .init(hidden: [], blocked: [], deleted: []), identityNames: [:])
        }
        let original = window(["retained", "text"])
        #expect(window(["retained", "another-text"]).hasSameMedia(as: original, pages: pages))
        #expect(!window(["text"]).hasSameMedia(as: original, pages: pages))
    }

    @Test func aReplacedWindowStaysSeparateUntilItReconnectsToTheSelectedPhoto() throws {
        let photo = entry("selected")
        let id = try #require(TranscriptHistorySlot(photo)).attachment.id
        var pages = TranscriptHistoryPages()
        pages.append([entry("newer"), photo])
        #expect(pages.extensions(around: [], excluding: [], preserving: id).older.map(\.target.messageIdHex) == ["selected", "newer"])
        #expect(pages.extensions(around: [], excluding: ["selected"], preserving: id).older.isEmpty)
        #expect(pages.extensions(around: [], excluding: [], preserving: "removed").older.isEmpty)

        let replacement = entry("replacement")
        let window = [try #require(TranscriptHistorySlot(replacement)).attachment]
        let disconnected = pages.extensions(around: window, excluding: ["replacement"], preserving: id)
        #expect(!disconnected.includesWindow)
        #expect(disconnected.older.map(\.target.messageIdHex) == ["selected", "newer"])

        var refreshed = TranscriptHistoryPages()
        refreshed.append([replacement, entry("newer"), photo])
        let connected = refreshed.extensions(around: window, excluding: ["replacement"], preserving: id)
        #expect(connected.includesWindow)
        #expect(connected.older.map(\.target.messageIdHex) == ["selected", "newer"])
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

    @Test func locallyHiddenAndBlockedAttachmentsStayOutOfHistory() throws {
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
