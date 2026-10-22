import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

struct ComposerMediaDraftLayoutTests {
    @Test func mediaSelectionReviewsOnlyVisualDraftsAndPreservesOtherAttachmentOrder() throws {
        let firstImage = MediaDraftAttachment(
            fileName: "first.jpg",
            mediaType: "image/jpeg",
            data: Data([1]),
            dim: "100x100"
        )
        let document = MediaDraftAttachment(
            fileName: "notes.txt",
            mediaType: "text/plain",
            data: Data([2]),
            dim: nil
        )
        let video = MediaDraftAttachment(
            fileName: "clip.mp4",
            mediaType: "video/mp4",
            data: Data([3]),
            dim: "1920x1080"
        )
        let all = [firstImage, document, video]
        let selection = try #require(ComposerMediaSelection(
            attachments: all,
            initialItemID: firstImage.id
        ))

        #expect(selection.attachments.map(\.id) == [firstImage.id, video.id])
        #expect(selection.applying(includedItemIDs: [video.id], to: all).map(\.id) == [document.id, video.id])
        #expect(selection.applying(includedItemIDs: [], to: all).map(\.id) == [document.id])
    }
}
