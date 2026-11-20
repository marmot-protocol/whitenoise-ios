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

    @Test func singleVisualSizeUsesTheSameCanvasForPhotosVideosAndCaptions() {
        #expect(MessageVisualMediaBubblePresentation.displaySize(maxWidth: 256, dim: "1080x1920") == CGSize(width: 192, height: 256))
        #expect(MessageVisualMediaBubblePresentation.displaySize(maxWidth: 256, dim: "640x360") == CGSize(width: 256, height: 144))
        #expect(MessageVisualMediaBubblePresentation.displaySize(maxWidth: 256, dim: "32x32") == CGSize(width: 192, height: 192))
        #expect(MessageVisualMediaBubblePresentation.displaySize(maxWidth: 256, dim: "10000x1") == CGSize(width: 256, height: 90))
    }

    @Test func aPhotoSetsTheContentWidthWhenFilesShareItsBubble() {
        func item(_ name: String, _ mediaType: String, dim: String? = nil) -> MessageMediaAttachment {
            MessageMediaAttachment(id: name, reference: nil, fileName: name, mediaType: mediaType,
                                  dim: dim, localData: nil)
        }

        let portrait = item("portrait.jpg", "image/jpeg", dim: "1080x1920")
        let landscape = item("landscape.jpg", "image/jpeg", dim: "640x360")
        let file = item("route.pdf", "application/pdf")
        let video = item("clip.mp4", "video/mp4", dim: "1080x1920")

        #expect(MessageVisualMediaBubblePresentation.contentWidth(for: [portrait, file], maxWidth: 256) == 192)
        let unknownFile = item("route.bin", "application/octet-stream")
        let unavailable = MessageMediaAttachment(id: "rejected", reference: nil, fileName: "Attachment",
                                                mediaType: "", dim: nil, localData: nil, rejectionKind: .unsupportedFormat)
        #expect(MessageVisualMediaBubblePresentation.contentWidth(for: [portrait, unavailable], maxWidth: 256) == 192)
        for companion in [item("voice.m4a", "audio/mp4"), item("loop.gif", "image/gif")] {
            #expect(MessageVisualMediaBubblePresentation.contentWidth(for: [portrait, companion], maxWidth: 256) == 256)
        }
        #expect(MessageVisualMediaBubblePresentation.contentWidth(for: [unknownFile, portrait], maxWidth: 256) == 192)
        #expect(MessageVisualMediaBubblePresentation.contentWidth(for: [file, landscape], maxWidth: 256) == 256)
        #expect(MessageVisualMediaBubblePresentation.contentWidth(for: [portrait, landscape, file], maxWidth: 256) == 256)
        #expect(MessageVisualMediaBubblePresentation.contentWidth(for: [video, file], maxWidth: 256) == 256)
    }

    @Test(arguments: [nil, "bad", "0x400", "20xinf"] as [String?])
    func unusableDimensionsReserveASquare(_ dimensions: String?) {
        #expect(MessageVisualMediaBubblePresentation.displaySize(maxWidth: 256, dim: dimensions) == CGSize(width: 256, height: 256))
    }

    // MARK: - Media cache keys
    //
    // Thumbnail, video and audio each carry their own cacheKey; one
    // parameterized pair covers all three.

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
