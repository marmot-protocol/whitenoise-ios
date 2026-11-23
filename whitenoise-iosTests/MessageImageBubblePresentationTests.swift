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

    @Test(arguments: [CGFloat(256), 300])
    func singleMediaFitsTheAvailableWidthWhilePreservingOrdinaryAspectRatios(_ maxWidth: CGFloat) {
        func size(_ dim: String) -> CGSize { MessageVisualMediaBubblePresentation.displaySize(maxWidth: maxWidth, dim: dim) }
        let landscape = size("640x360"), portrait = size("800x1000")
        #expect(landscape.width == maxWidth && portrait.height == maxWidth)
        #expect(abs(landscape.height - landscape.width * 9 / 16) <= 1)
        #expect(abs(portrait.width - portrait.height * 4 / 5) <= 1)
        let narrow = size("1080x1920"), square = size("32x32"), panorama = size("10000x1")
        #expect(narrow.width < narrow.height && narrow.height == maxWidth)
        #expect(narrow.width > narrow.height * 9 / 16)
        #expect(square.width == square.height && square.width < maxWidth)
        #expect(panorama.width == maxWidth && panorama.height < landscape.height)
        #expect(panorama.height > panorama.width / 10_000)
    }

    @Test func aPhotoSetsTheContentWidthWhenFilesShareItsBubble() {
        let maxWidth: CGFloat = 300
        func item(_ name: String, _ mediaType: String, dim: String? = nil) -> MessageMediaAttachment {
            MessageMediaAttachment(id: name, reference: nil, fileName: name, mediaType: mediaType,
                                  dim: dim, localData: nil)
        }

        let portrait = item("portrait.jpg", "image/jpeg", dim: "1080x1920")
        let landscape = item("landscape.jpg", "image/jpeg", dim: "640x360")
        let file = item("route.pdf", "application/pdf")
        let video = item("clip.mp4", "video/mp4", dim: "1080x1920")

        let portraitWidth = MessageVisualMediaBubblePresentation.displaySize(maxWidth: maxWidth, dim: portrait.dim).width
        #expect(portraitWidth < maxWidth)
        func width(_ items: [MessageMediaAttachment]) -> CGFloat {
            MessageVisualMediaBubblePresentation.contentWidth(for: items, maxWidth: maxWidth)
        }
        let unknownFile = item("route.bin", "application/octet-stream")
        let unavailable = MessageMediaAttachment(id: "rejected", reference: nil, fileName: "Attachment",
                                                mediaType: "", dim: nil, localData: nil, rejectionKind: .unsupportedFormat)
        for files in [[portrait, file], [portrait, unavailable], [unknownFile, portrait]] {
            #expect(width(files) == portraitWidth)
        }
        for companion in [item("voice.m4a", "audio/mp4"), item("loop.gif", "image/gif")] {
            #expect(width([portrait, companion]) == maxWidth)
        }
        #expect(width([file, landscape]) == maxWidth)
        #expect(width([portrait, landscape, file]) == maxWidth)
        #expect(width([video, file]) == maxWidth)
    }

    @Test(arguments: [nil, "bad", "0x400", "20xinf"] as [String?])
    func unusableDimensionsReserveASquare(_ dimensions: String?) {
        let maxWidth: CGFloat = 280
        let size = MessageVisualMediaBubblePresentation.displaySize(maxWidth: maxWidth, dim: dimensions)
        #expect(size.width == maxWidth && size.height == size.width)
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
