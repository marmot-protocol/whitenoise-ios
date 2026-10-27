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

    @Test func galleryRejectsNonVisualInitialItem() {
        let image = attachment(id: "image", mediaType: "image/png")
        let document = attachment(id: "document", mediaType: "application/pdf")

        let gallery = MessageMediaGallery(
            items: [image, document],
            initialItem: document,
            initialImageData: Data()
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
            initialImageData: imageData()
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
            initialImageData: data
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
