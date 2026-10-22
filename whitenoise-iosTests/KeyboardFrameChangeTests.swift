import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

@MainActor
struct KeyboardFrameChangeTests {

    @Test func animationParametersPreserveKeyboardTiming() {
        let parameters = KeyboardFrameChange.animationParameters(duration: 0.42, rawCurve: 1)
        #expect(parameters.duration == 0.42)
        #expect(parameters.curve == .easeIn)
    }

    @Test func animationParametersUseStableDefaultsForUnknownCurve() {
        let parameters = KeyboardFrameChange.animationParameters(duration: nil, rawCurve: 7)
        #expect(parameters.duration == 0.25)
        #expect(parameters.curve == .easeInOut)
    }

    @Test func bottomGapUpdatesOnlyForMaterialChanges() {
        #expect(!KeyboardFrameChange.shouldUpdateBottomGap(current: 16, next: 16.25))
        #expect(KeyboardFrameChange.shouldUpdateBottomGap(current: 0, next: 16))
    }

    @Test func visibilityUpdatesOnlyWhenValueChanges() {
        #expect(!KeyboardFrameChange.shouldUpdateVisibility(current: true, next: true))
        #expect(KeyboardFrameChange.shouldUpdateVisibility(current: false, next: true))
    }
}
