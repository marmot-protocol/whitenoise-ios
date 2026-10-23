import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

struct MessageImageBubblePresentationTests {

    @Test func mediaOnlyPortraitBubbleWrapsRenderedImageWidth() {
        let renderedSize = MessageImageBubblePresentation.displaySize(
            maxWidth: 300,
            dim: "1080x1920"
        )

        #expect(MessageRichMediaBubblePresentation.contentWidth(
            maxWidth: 300,
            singleVisualWidth: renderedSize.width,
            hasCaption: false,
            hasReply: false
        ) == renderedSize.width)
    }

    @Test func captionOrReplyKeepsRichMediaBubbleReadable() {
        #expect(MessageRichMediaBubblePresentation.contentWidth(
            maxWidth: 300,
            singleVisualWidth: 228,
            hasCaption: true,
            hasReply: false
        ) == 300)
        #expect(MessageRichMediaBubblePresentation.contentWidth(
            maxWidth: 300,
            singleVisualWidth: 228,
            hasCaption: false,
            hasReply: true
        ) == 300)
    }

    @Test func landscapeImageUsesActualAspectRatio() {
        let size = MessageImageBubblePresentation.displaySize(maxWidth: 300, dim: "640x360")

        #expect(size.width == 300)
        #expect(size.height == 169)
    }

    @Test func portraitImageNarrowsAndCapsItsHeight() {
        let size = MessageImageBubblePresentation.displaySize(maxWidth: 300, dim: "1080x1920")

        #expect(size.width == 228)
        #expect(size.height == 405)
    }

    @Test func captionedPortraitImageFillsTheBubbleMediaWidth() {
        let size = MessageImageBubblePresentation.displaySize(
            maxWidth: 300,
            dim: "1080x1920",
            fillsWidth: true
        )

        #expect(size.width == 300)
        #expect(size.height == 405)
    }

    @Test func captionedLandscapeImageKeepsItsUnfilledSize() {
        let filled = MessageImageBubblePresentation.displaySize(
            maxWidth: 300,
            dim: "640x360",
            fillsWidth: true
        )

        #expect(filled == MessageImageBubblePresentation.displaySize(maxWidth: 300, dim: "640x360"))
    }

    @Test func captionedShallowPortraitImageNeedsNoCrop() {
        let filled = MessageImageBubblePresentation.displaySize(
            maxWidth: 300,
            dim: "900x1000",
            fillsWidth: true
        )

        #expect(filled == MessageImageBubblePresentation.displaySize(maxWidth: 300, dim: "900x1000"))
        #expect(filled == CGSize(width: 300, height: 333))
    }

    @Test func captionOrReplyMakesTheSingleVisualFillTheBubble() {
        #expect(MessageRichMediaBubblePresentation.singleVisualFillsBubbleWidth(
            hasCaption: false,
            hasReply: false
        ) == false)
        #expect(MessageRichMediaBubblePresentation.singleVisualFillsBubbleWidth(
            hasCaption: true,
            hasReply: false
        ))
        #expect(MessageRichMediaBubblePresentation.singleVisualFillsBubbleWidth(
            hasCaption: false,
            hasReply: true
        ))
    }

    @Test func missingOrMalformedImageDimensionsUseSquareFallback() {
        #expect(MessageImageBubblePresentation.displaySize(maxWidth: 300, dim: nil) == CGSize(width: 300, height: 300))
        #expect(MessageImageBubblePresentation.displaySize(maxWidth: 300, dim: "bad") == CGSize(width: 300, height: 300))
        #expect(MessageImageBubblePresentation.displaySize(maxWidth: 300, dim: "0x400") == CGSize(width: 300, height: 300))
    }

    @Test func extremeImageDimensionsAreClamped() {
        #expect(MessageImageBubblePresentation.aspectRatio(dim: "10000x1") == 4)
        #expect(MessageImageBubblePresentation.aspectRatio(dim: "1x10000") == 0.25)
    }

    // MARK: - Media cache keys
    //
    // MessageMediaThumbnailPresentation, MessageVideoThumbnailPresentation and
    // MessageAudioBubblePresentation each carry their own cacheKey; one
    // parameterized pair covers all three (merged from
    // MessageMediaThumbnailPresentationTests and the audio pair of
    // MessageAudioBubblePresentationTests).

    enum CacheKeyKind: String, CaseIterable, Sendable {
        case thumbnail, video, audio

        func cacheKey(for item: MessageMediaAttachment) -> String {
            switch self {
            case .thumbnail: MessageMediaThumbnailPresentation.cacheKey(for: item)
            case .video: MessageVideoThumbnailPresentation.cacheKey(for: item)
            case .audio: MessageAudioBubblePresentation.cacheKey(for: item)
            }
        }

        var fileName: String {
            switch self {
            case .thumbnail: "photo.jpg"
            case .video: "clip.mp4"
            case .audio: "voice.m4a"
            }
        }

        var mediaType: String {
            switch self {
            case .thumbnail: "image/jpeg"
            case .video: "video/mp4"
            case .audio: "audio/mp4"
            }
        }

        var dim: String? { self == .audio ? nil : "640x480" }
    }

    @Test(arguments: CacheKeyKind.allCases)
    func mediaCacheKeySurvivesSourceEpochRefresh(kind: CacheKeyKind) {
        let initial = attachment(
            id: "row:\(hex("33")):0:0",
            reference: encryptedMediaReference(
                fileName: kind.fileName,
                mediaType: kind.mediaType,
                dim: kind.dim,
                sourceEpoch: 0
            )
        )
        let refreshed = attachment(
            id: "row:\(hex("33")):42:0",
            reference: encryptedMediaReference(
                fileName: kind.fileName,
                mediaType: kind.mediaType,
                dim: kind.dim,
                sourceEpoch: 42
            )
        )

        #expect(kind.cacheKey(for: initial) == kind.cacheKey(for: refreshed))
    }

    @Test(arguments: CacheKeyKind.allCases)
    func mediaCacheKeyFallsBackToItemIdForLocalMedia(kind: CacheKeyKind) {
        let local = attachment(id: "local-\(kind.rawValue)", reference: nil)

        #expect(kind.cacheKey(for: local) == "item:local-\(kind.rawValue)")
    }

    private func attachment(
        id: String,
        reference: MediaAttachmentReferenceFfi?
    ) -> MessageMediaAttachment {
        MessageMediaAttachment(
            id: id,
            reference: reference,
            fileName: reference?.fileName ?? "local.bin",
            mediaType: reference?.mediaType ?? "application/octet-stream",
            dim: reference?.dim,
            localData: nil
        )
    }
}
