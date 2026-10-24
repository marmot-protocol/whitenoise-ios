import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

struct ComposerMediaDraftPresentationTests {

    @Test func singleAudioDraftMovesIntoInlineComposerPreview() {
        let audio = draft(id: UUID(), mediaType: "audio/mp4")

        #expect(ComposerMediaDraftPresentation.inlineAudioDraft(in: [audio])?.id == audio.id)
        #expect(ComposerMediaDraftPresentation.stripAttachments(from: [audio]).isEmpty)
    }

    @Test func nonAudioDraftsStayInAttachmentStrip() {
        let image = draft(id: UUID(), mediaType: "image/jpeg")
        let document = draft(id: UUID(), mediaType: "application/pdf")

        #expect(ComposerMediaDraftPresentation.inlineAudioDraft(in: [image, document]) == nil)
        #expect(ComposerMediaDraftPresentation.stripAttachments(from: [image, document]).map(\.id) == [image.id, document.id])
    }

    @Test func mixedDraftsKeepOnlyAudioInComposerInput() {
        let image = draft(id: UUID(), mediaType: "image/jpeg")
        let audio = draft(id: UUID(), mediaType: "audio/mp4")

        #expect(ComposerMediaDraftPresentation.inlineAudioDraft(in: [image, audio])?.id == audio.id)
        #expect(ComposerMediaDraftPresentation.stripAttachments(from: [image, audio]).map(\.id) == [image.id])
    }

    private func draft(id: UUID, mediaType: String) -> MediaDraftAttachment {
        MediaDraftAttachment(
            id: id,
            fileName: "\(id.uuidString).bin",
            mediaType: mediaType,
            data: Data([0x01]),
            dim: nil,
            durationSeconds: mediaType.hasPrefix("audio/") ? 2.4 : nil,
            waveformSamples: mediaType.hasPrefix("audio/") ? [0.2, 0.8, 0.4] : []
        )
    }
}
