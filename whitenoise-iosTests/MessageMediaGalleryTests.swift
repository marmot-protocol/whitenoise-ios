import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

@MainActor
struct MessageMediaGalleryTests {

    @Test func tappingAVideoInChatPlaysItAndSwipingWaitsForAnotherPlayTap() {
        nonisolated final class TestPlayer: AVPlayer {
            let playCount = Mutex(0)
            var plays: Int { playCount.withLock { $0 } }
            override func play() { playCount.withLock { $0 += 1 } }
            override func pause() {}
        }
        let player = TestPlayer()
        var selection = TranscriptMediaSelection(openingID: "first video")
        func presentSelection() {
            let demand = selection.demand(for: selection.selectedID, allowsOpeningDemand: true)
            MessageMediaFullscreenGalleryPresentation.prepareVideo(player, demand: demand)
        }
        selection.select("first video")
        presentSelection()
        #expect(player.plays == 1)
        selection.select("another video")
        presentSelection()
        #expect(player.plays == 1)
        MessageMediaFullscreenGalleryPresentation.prepareVideo(player, demand: .userTap(afterFailure: false))
        #expect(player.plays == 2)
        selection.select("first video")
        presentSelection()
        #expect(player.plays == 2)
        let restored = TranscriptMediaSelection(openingID: selection.selectedID)
        MessageMediaFullscreenGalleryPresentation.prepareVideo(player, demand: restored.demand(for: restored.selectedID, allowsOpeningDemand: false))
        #expect(player.plays == 2)

        var outgoing = TranscriptMediaSelection(openingID: "draft")
        let pending = PendingVideoPlayback()
        pending.request(.explicit)
        outgoing.confirm("confirmed slot", resumeVideo: pending.wantsPlayback == true)
        let confirmedDemand = outgoing.demand(for: outgoing.selectedID, allowsOpeningDemand: true)
        #expect(confirmedDemand == .automatic)
        MessageMediaFullscreenGalleryPresentation.prepareVideo(player, demand: confirmedDemand,
            resumeConfirmed: outgoing.resumingVideoID == outgoing.selectedID)
        #expect(player.plays == 3)
        outgoing.select("another video")
        outgoing.select("confirmed slot")
        #expect(outgoing.resumingVideoID == nil)

        let paused = AVPlayer()
        pending.observe(paused)
        pending.detach(paused)
        #expect(pending.wantsPlayback == false)
    }

    @Test func confirmedPhotoMustMatchTheSelectedDraftsRowSlotAndBytes() async throws {
        let slot = MessageMediaGallery.OutgoingSlot(rowID: "my-send", index: 1)
        let draft = MessageMediaGallery.PendingSelection(id: "draft", slot: slot, data: Data("abc".utf8))
        let reference = MediaAttachmentReferenceFfi(locators: [], ciphertextSha256: "", plaintextSha256:
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", nonceHex: "", fileName: "photo.jpg",
            mediaType: "image/jpeg", version: .v1, sourceEpoch: 1, dim: nil, thumbhash: nil)
        let items = MessageMediaAttachment.displayItems(from: [reference, reference], ownerId: "row")
        let captions: [String: MessageMediaGallery.Caption] = [
            items[0].id: .init(sender: "You", date: .now, outgoingSlot: .init(rowID: "other", index: 1)),
            items[1].id: .init(sender: "You", date: .now, outgoingSlot: slot)
        ]
        let gallery = try #require(MessageMediaGallery(transcriptItems: items, openingID: draft.id,
            initialData: nil, messages: [:], captions: captions))
        #expect(await gallery.confirmedSelection(for: draft)?.id == items[1].id)
        #expect(await gallery.confirmedSelection(for: .init(id: "draft", slot: slot, data: Data("edited".utf8))) == nil)
        #expect(await gallery.confirmedSelection(for: .init(id: "draft", slot: .init(rowID: "my-send", index: 0),
            data: draft.data)) == nil)
    }

    @Test func aPreparedPhotoAcceptsItsFirstOriginalSlotAndRejectsAReplacement() throws {
        var ref = MediaAttachmentReferenceFfi(locators: [], ciphertextSha256: "", plaintextSha256: "photo",
            nonceHex: "", fileName: "photo.png", mediaType: "image/png", version: .v1,
            sourceEpoch: 1, dim: nil, thumbhash: nil)
        let pending = try #require(MessageMediaAttachment.displayItems(from: [ref], ownerId: "row").first)
        var source = pending
        source.localTarget = .init(messageIdHex: "message", sourceMessageIdHex: "confirmation", attachmentIndex: 0)
        #expect(source.canUseBytesPrepared(for: pending))
        let draft = MessageMediaAttachment(id: "draft", reference: nil, fileName: "photo.png",
            mediaType: "image/png", dim: nil, localData: Data([1, 2, 3]))
        var sends = OwnSendMediaStore()
        sends.retain(draft, plaintextSha256: ref.plaintextSha256)
        let receivedCopy = sends.overlay(source)
        #expect(receivedCopy.localData == draft.localData)
        #expect(receivedCopy.forTranscriptPage.localData == nil)
        #expect(receivedCopy.forTranscriptPage.localTarget == source.localTarget)
        var hinted = pending
        hinted.sourceHint = .init(messageID: "message", slot: 0)
        let hintedCopy = sends.overlay(hinted)
        #expect(hintedCopy.localData == draft.localData)
        #expect(hintedCopy.forTranscriptPage.localData == nil)
        #expect(hintedCopy.forTranscriptPage.sourceHint == hinted.sourceHint)
        #expect(!hintedCopy.canUseBytesPrepared(for: pending))
        #expect(draft.forTranscriptPage.localData == draft.localData)
        var edited = source
        edited.localTarget?.sourceMessageIdHex = "replacement"
        #expect(!edited.canUseBytesPrepared(for: source))
        ref.fileName = "different.png"
        let different = try #require(MessageMediaAttachment.displayItems(from: [ref], ownerId: "row").first)
        #expect(!different.canUseBytesPrepared(for: pending))
    }

    @Test func preparedTranscriptPhotoNeedsLiveSlotVerificationToExport() async throws {
        let photo = attachment(id: "photo", mediaType: "image/png")
        let gallery = try #require(MessageMediaGallery(transcriptItems: [photo], openingID: photo.id,
            initialData: imageData(), messages: [:], captions: [photo.id: .init(sender: "You", date: .now)]))
        await #expect(throws: CancellationError.self) { try await gallery.mayExport(photo, verify: nil) }
        #expect(try await gallery.mayExport(photo, verify: { _ in false }) == false)
        #expect(try await gallery.mayExport(photo, verify: { $0.id == photo.id }))
    }

    @Test func galleryRejectsNonVisualInitialItem() {
        let image = attachment(id: "image", mediaType: "image/png")
        let document = attachment(id: "document", mediaType: "application/pdf")

        let gallery = MessageMediaGallery(
            items: [image, document],
            initialItem: document,
            initialMediaData: Data()
        )

        #expect(gallery == nil)
    }

    @Test func galleryKeepsImageAndVideoPagesWhenInitialImageIsInList() throws {
        let image = attachment(id: "image", mediaType: "image/png")
        let video = attachment(id: "video", mediaType: "video/mp4")
        let document = attachment(id: "document", mediaType: "application/pdf")

        let gallery = try #require(MessageMediaGallery(
            items: [image, video, document],
            initialItem: image,
            initialMediaData: imageData()
        ))

        #expect(gallery.items.map(\.id) == ["image", "video"])
        #expect(gallery.initialItemID == "image")
    }

    @Test func galleryRetainsMessageDestinationsForVisualItems() throws {
        let image = attachment(id: "image", mediaType: "image/png")
        let video = attachment(id: "video", mediaType: "video/mp4")
        let document = attachment(id: "document", mediaType: "application/pdf")
        let messageIds = [
            image.id: "image-message",
            video.id: "video-message",
            document.id: "document-message",
        ]

        let gallery = try #require(MessageMediaGallery(
            items: [image, video, document],
            initialItem: image,
            messageIdByItemID: messageIds
        ))

        #expect(gallery.messageIdByItemID[image.id] == "image-message")
        #expect(gallery.messageIdByItemID[video.id] == "video-message")
    }

    @Test func galleryAcceptsVideoInitialItem() throws {
        let image = attachment(id: "image", mediaType: "image/png")
        let video = attachment(id: "video", mediaType: "video/mp4")
        let document = attachment(id: "document", mediaType: "application/pdf")

        let gallery = try #require(MessageMediaGallery(
            items: [image, video, document],
            initialItem: video,
            initialMediaData: nil
        ))

        #expect(gallery.items.map(\.id) == ["image", "video"])
        #expect(gallery.initialItemID == "video")
        #expect(gallery.initialData(for: video) == nil)
    }

    @Test func galleryPrependsMissingVisualInitialItem() throws {
        let initial = attachment(id: "initial", mediaType: "image/png")
        let otherImage = attachment(id: "other", mediaType: "image/jpeg")
        let video = attachment(id: "video", mediaType: "video/quicktime")
        let document = attachment(id: "document", mediaType: "application/pdf")
        let data = imageData()

        let gallery = try #require(MessageMediaGallery(
            items: [document, otherImage, video],
            initialItem: initial,
            initialMediaData: data
        ))

        #expect(gallery.items.map(\.id) == ["initial", "other", "video"])
        #expect(gallery.initialData(for: initial) == data)
        #expect(gallery.initialData(for: otherImage) == nil)
    }

    @Test func pageCountLabelUsesLocalizedCatalogPhrase() {
        #expect(MessageMediaFullscreenGalleryPresentation.pageCountLabel(
            selectedIndex: 1,
            totalCount: 12,
            locale: Locale(identifier: "fr")
        ) == "2 sur 12")
    }

    @Test func pageCountLabelLocalizesDigits() {
        let locale = Locale(identifier: "ar_EG")
        let label = MessageMediaFullscreenGalleryPresentation.pageCountLabel(
            selectedIndex: 1,
            totalCount: 12,
            locale: locale
        )

        #expect(label.contains(LocalizedNumberLabel.decimal(2, locale: locale)))
        #expect(label.contains(LocalizedNumberLabel.decimal(12, locale: locale)))
        #expect(label != "2 of 12")
    }

    @Test func pageCountLabelFallsBackToEmptyWhenSelectionIsMissing() {
        #expect(MessageMediaFullscreenGalleryPresentation.pageCountLabel(
            selectedIndex: nil,
            totalCount: 3
        ).isEmpty)
    }

    @Test func fullscreenInitialDecodeFailureIsExplicit() async {
        // Invalid bytes decode to nil off-main rather than crashing or
        // returning a bogus image.
        #expect(await MessageMediaFullscreenPresentation.decodedImage(
            from: Data([0x00]),
            maxPixelSize: 64,
            scale: 1
        ) == nil)
        // Nil data short-circuits to nil without touching the decoder.
        #expect(await MessageMediaFullscreenPresentation.decodedImage(
            from: nil,
            maxPixelSize: 64,
            scale: 1
        ) == nil)
        // Valid bytes decode to a bounded, non-empty image.
        let decoded = await MessageMediaFullscreenPresentation.decodedImage(
            from: imageData(),
            maxPixelSize: 64,
            scale: 1
        )
        #expect(decoded != nil)
        #expect((decoded?.size.width ?? 0) > 0)
    }

    @Test func fullscreenMaxPixelSizeAllowsZoomButCapsDecodedPixels() {
        #expect(MessageMediaFullscreenPresentation.fullscreenMaxPixelSize(forLongestScreenEdge: 2532) == 4096)
        #expect(MessageMediaFullscreenPresentation.fullscreenMaxPixelSize(forLongestScreenEdge: 0) == 1)
        #expect(MessageMediaFullscreenPresentation.fullscreenMaxPixelSize(forLongestScreenEdge: -10) == 1)
        #expect(MessageMediaFullscreenPresentation.fullscreenMaxPixelSize(forLongestScreenEdge: .infinity) == 1)
        #expect(MessageMediaFullscreenPresentation.fullscreenMaxPixelSize(forLongestScreenEdge: 100.4) == 201)
    }

    @Test func thumbnailCacheRetainsSourceDataForFullscreenReuse() async throws {
        let data = imageData()
        let itemID = "cache-warm-image-\(UUID().uuidString)"
        let decoded = try #require(await MessageMediaThumbnailDecoder.image(
            data: data,
            maxPixelSize: 32,
            scale: 1
        ))

        MessageMediaThumbnailDecoder.store(decoded, sourceData: data, for: itemID, maxPixelSize: 32)

        let cached = try #require(MessageMediaThumbnailDecoder.cachedThumbnail(for: itemID, maxPixelSize: 32))
        #expect(cached.sourceData == data)
        #expect(cached.image.size.width > 0)
    }

    private func attachment(
        id: String,
        mediaType: String,
        localData: Data? = nil
    ) -> MessageMediaAttachment {
        MessageMediaAttachment(
            id: id,
            reference: nil,
            fileName: "\(id).bin",
            mediaType: mediaType,
            dim: nil,
            localData: localData
        )
    }

    private func imageData() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }
}
