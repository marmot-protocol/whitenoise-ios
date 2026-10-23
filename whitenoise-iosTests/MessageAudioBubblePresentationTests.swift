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

    // MARK: - Composer draft preview

    @Test func playbackIconReflectsPreviewState() {
        #expect(ComposerAudioDraftPreviewPresentation.playIconName(isPlaying: false, didFail: false) == "play.fill")
        #expect(ComposerAudioDraftPreviewPresentation.playIconName(isPlaying: true, didFail: false) == "pause.fill")
        #expect(ComposerAudioDraftPreviewPresentation.playIconName(isPlaying: false, didFail: true) == "arrow.clockwise")
    }

    @Test func durationLabelMatchesComposerPreviewFormat() {
        #expect(ComposerAudioDraftPreviewPresentation.durationLabel(nil) == "")
        #expect(ComposerAudioDraftPreviewPresentation.durationLabel(2.9) == "0:02")
        #expect(ComposerAudioDraftPreviewPresentation.durationLabel(65) == "1:05")
    }

    @Test func durationLabelClampsNonFiniteDraftDurations() {
        #expect(ComposerAudioDraftPreviewPresentation.durationLabel(.nan) == "0:00")
        #expect(ComposerAudioDraftPreviewPresentation.durationLabel(.infinity) == "0:00")
        #expect(ComposerAudioDraftPreviewPresentation.durationLabel(-.infinity) == "0:00")
    }

    @Test func durationLabelUsesLocalizedDigits() {
        let locale = Locale(identifier: "ar_EG")
        let expected = L10n.formatted(
            "%@:%@",
            arguments: [
                String(format: "%lld", locale: locale, Int64(1)),
                String(format: "%02lld", locale: locale, Int64(5))
            ],
            locale: locale
        )

        #expect(AudioDurationLabel.label(for: 65, locale: locale) == expected)
        #expect(AudioDurationLabel.label(for: 65, locale: locale) != "1:05")
    }

    // MARK: - Camera capture

    @Test func recordingDurationUsesMinuteAndZeroPaddedSecondFields() {
        #expect(CameraCapturePresentation.durationLabel(0) == "0:00")
        #expect(CameraCapturePresentation.durationLabel(9.99) == "0:09")
        #expect(CameraCapturePresentation.durationLabel(65) == "1:05")
        #expect(CameraCapturePresentation.durationLabel(-2) == "0:00")
    }
}
