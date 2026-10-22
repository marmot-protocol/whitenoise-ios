import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

struct MessageMediaThumbnailPresentationTests {

    @Test func thumbnailCacheKeySurvivesSourceEpochRefresh() {
        let initial = attachment(
            id: "row:\(hex("33")):0:0",
            reference: encryptedMediaReference(
                fileName: "photo.jpg",
                mediaType: "image/jpeg",
                dim: "640x480",
                sourceEpoch: 0
            )
        )
        let refreshed = attachment(
            id: "row:\(hex("33")):42:0",
            reference: encryptedMediaReference(
                fileName: "photo.jpg",
                mediaType: "image/jpeg",
                dim: "640x480",
                sourceEpoch: 42
            )
        )

        #expect(MessageMediaThumbnailPresentation.cacheKey(for: initial) == MessageMediaThumbnailPresentation.cacheKey(for: refreshed))
    }

    @Test func thumbnailCacheKeyFallsBackToItemIdForLocalImage() {
        let local = attachment(id: "local-image", reference: nil)

        #expect(MessageMediaThumbnailPresentation.cacheKey(for: local) == "item:local-image")
    }

    private func attachment(
        id: String,
        reference: MediaAttachmentReferenceFfi?
    ) -> MessageMediaAttachment {
        MessageMediaAttachment(
            id: id,
            reference: reference,
            fileName: reference?.fileName ?? "local.jpg",
            mediaType: reference?.mediaType ?? "image/jpeg",
            dim: reference?.dim,
            localData: nil
        )
    }
}
