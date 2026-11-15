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

    @Test func playbackWaveformAmplifiesQuietSamples() {
        let bars = AudioWaveformPresentation.bars(for: [0.2, 0.8], count: 2)

        #expect((bars[0].amplitude ?? 0) > 0.45)
        #expect((bars[1].amplitude ?? 0) > 0.9)
    }

    @Test func playbackWaveformStillFallsBackWhenSamplesAreMissing() {
        let bars = AudioWaveformPresentation.bars(for: [], count: 5)

        #expect(bars.count == 5)
        #expect(bars.map(\.isVisible) == Array(repeating: true, count: 5))
    }
}
