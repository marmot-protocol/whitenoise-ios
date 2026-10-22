import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

struct MessageAudioBubblePresentationTests {
    @Test func playbackIconReflectsPlayerState() {
        #expect(MessageAudioBubblePresentation.playbackIconName(isPlaying: false, didFail: false) == "play.fill")
        #expect(MessageAudioBubblePresentation.playbackIconName(isPlaying: true, didFail: false) == "pause.fill")
        #expect(MessageAudioBubblePresentation.playbackIconName(isPlaying: false, didFail: true) == "arrow.clockwise")
        #expect(MessageAudioBubblePresentation.playbackIconName(isPlaying: true, didFail: true) == "pause.fill")
    }

    @Test func missingDurationDoesNotReserveLabelSpace() {
        #expect(MessageAudioBubblePresentation.durationLabel(nil) == nil)
    }

    @Test func durationLabelMatchesBubbleFormat() {
        #expect(MessageAudioBubblePresentation.durationLabel(2.9) == "0:02")
        #expect(MessageAudioBubblePresentation.durationLabel(65) == "1:05")
    }

    @Test func nonFiniteDurationDoesNotReserveLabelSpace() {
        #expect(MessageAudioBubblePresentation.durationLabel(.nan) == nil)
        #expect(MessageAudioBubblePresentation.durationLabel(.infinity) == nil)
        #expect(MessageAudioBubblePresentation.durationLabel(-.infinity) == nil)
    }

    @Test func audioMetadataCacheKeySurvivesSourceEpochRefresh() {
        let initial = attachment(
            id: "row:\(hex("33")):0:0",
            reference: encryptedMediaReference(
                fileName: "voice.m4a",
                mediaType: "audio/mp4",
                dim: nil,
                sourceEpoch: 0
            )
        )
        let refreshed = attachment(
            id: "row:\(hex("33")):42:0",
            reference: encryptedMediaReference(
                fileName: "voice.m4a",
                mediaType: "audio/mp4",
                dim: nil,
                sourceEpoch: 42
            )
        )

        #expect(MessageAudioBubblePresentation.cacheKey(for: initial) == MessageAudioBubblePresentation.cacheKey(for: refreshed))
    }

    @Test func audioMetadataCacheKeyFallsBackToItemIdForLocalAudio() {
        let local = attachment(id: "local-audio", reference: nil)

        #expect(MessageAudioBubblePresentation.cacheKey(for: local) == "item:local-audio")
    }

    private func attachment(
        id: String,
        reference: MediaAttachmentReferenceFfi?
    ) -> MessageMediaAttachment {
        MessageMediaAttachment(
            id: id,
            reference: reference,
            fileName: reference?.fileName ?? "local.m4a",
            mediaType: reference?.mediaType ?? "audio/mp4",
            dim: reference?.dim,
            localData: nil
        )
    }
}
