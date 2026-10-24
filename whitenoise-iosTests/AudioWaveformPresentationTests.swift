import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

struct AudioWaveformPresentationTests {

    @Test func liveRecordingStartsWithBlankWaveform() {
        let bars = AudioWaveformPresentation.bars(for: [], mode: .liveRecording, count: 5)

        #expect(bars.count == 5)
        #expect(bars.map(\.isVisible) == Array(repeating: false, count: 5))
    }

    @Test func liveRecordingAddsSamplesFromTrailingEdge() {
        let bars = AudioWaveformPresentation.bars(
            for: [0.2, 0.8],
            mode: .liveRecording,
            count: 5
        )

        #expect(bars.map(\.isVisible) == [false, false, false, true, true])
        #expect((bars[3].amplitude ?? 0) > 0.45)
        #expect((bars[4].amplitude ?? 0) > (bars[3].amplitude ?? 0))
    }

    @Test func liveRecordingKeepsNewestSamplesAfterWaveformFills() {
        let bars = AudioWaveformPresentation.bars(
            for: [0.1, 0.2, 0.3, 0.4],
            mode: .liveRecording,
            count: 3
        )

        #expect(bars.map(\.isVisible) == [true, true, true])
        #expect((bars[0].amplitude ?? 0) > 0.45)
        #expect((bars[1].amplitude ?? 0) > (bars[0].amplitude ?? 0))
        #expect((bars[2].amplitude ?? 0) > (bars[1].amplitude ?? 0))
    }

    @Test func playbackWaveformUsesSameAmplifiedCurveAsRecording() {
        let playbackBars = AudioWaveformPresentation.bars(for: [0.2, 0.8], mode: .playback, count: 2)
        let recordingBars = AudioWaveformPresentation.bars(for: [0.2, 0.8], mode: .liveRecording, count: 2)

        #expect(playbackBars.map(\.amplitude) == recordingBars.map(\.amplitude))
        #expect((playbackBars[0].amplitude ?? 0) > 0.45)
        #expect((playbackBars[1].amplitude ?? 0) > 0.9)
    }

    @Test func playbackWaveformStillFallsBackWhenSamplesAreMissing() {
        let bars = AudioWaveformPresentation.bars(for: [], mode: .playback, count: 5)

        #expect(bars.count == 5)
        #expect(bars.map(\.isVisible) == Array(repeating: true, count: 5))
    }
}
