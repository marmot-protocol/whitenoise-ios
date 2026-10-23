import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

struct MessageVideoBubblePresentationTests {

    @Test func portraitVideoNarrowsInsteadOfCropping() {
        let size = MessageVideoBubblePresentation.displaySize(maxWidth: 300, dim: "1080x1920")

        #expect(size.width < 300)
        #expect(size.height > size.width)
    }

    @Test func missingVideoDimensionsUseLandscapeFallback() {
        let size = MessageVideoBubblePresentation.displaySize(maxWidth: 300, dim: nil)

        #expect(size.width == 300)
        #expect(size.height == 169)
    }

    @Test func thumbnailCacheKeySurvivesSourceEpochRefresh() {
        let initial = attachment(
            id: "row:\(hex("33")):0:0",
            reference: encryptedMediaReference(
                fileName: "clip.mp4",
                mediaType: "video/mp4",
                dim: "640x360",
                sourceEpoch: 0
            )
        )
        let refreshed = attachment(
            id: "row:\(hex("33")):42:0",
            reference: encryptedMediaReference(
                fileName: "clip.mp4",
                mediaType: "video/mp4",
                dim: "640x360",
                sourceEpoch: 42
            )
        )

        #expect(MessageVideoThumbnailPresentation.cacheKey(for: initial) == MessageVideoThumbnailPresentation.cacheKey(for: refreshed))
    }

    @Test func thumbnailCacheKeyFallsBackToItemIdForLocalVideo() {
        let local = attachment(id: "local-video", reference: nil)

        #expect(MessageVideoThumbnailPresentation.cacheKey(for: local) == "item:local-video")
    }

    private func attachment(
        id: String,
        reference: MediaAttachmentReferenceFfi?
    ) -> MessageMediaAttachment {
        MessageMediaAttachment(
            id: id,
            reference: reference,
            fileName: reference?.fileName ?? "local.mov",
            mediaType: reference?.mediaType ?? "video/quicktime",
            dim: reference?.dim,
            localData: nil
        )
    }
}
