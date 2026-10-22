import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

struct ComposerInputChromeTests {
    @Test func lightModeComposerInputUsesLightSystemFill() {
        let lightFill = ComposerInputChrome.overlayFill(for: .light)
        let darkFill = ComposerInputChrome.overlayFill(for: .dark)

        #expect(lightFill.base == .systemBackground)
        #expect(lightFill.opacity > darkFill.opacity)
    }

    @Test func darkModeComposerInputKeepsSmokyOverlay() {
        let fill = ComposerInputChrome.overlayFill(for: .dark)

        #expect(fill.base == .black)
        #expect(fill.opacity == 0.26)
    }

    @Test func compactComposerMetricsMatchThePrototypeWithoutShrinkingHitTargets() {
        #expect(ComposerInputChrome.controlSize == 44)
        #expect(ComposerInputChrome.sendButtonSize == 32)
        #expect(ComposerInputChrome.cornerRadius == 22)
        #expect(ComposerInputChrome.rowSpacing == 8)
        #expect(ComposerInputChrome.inputSpacing == 4)
        #expect(ComposerInputChrome.horizontalInset == 16)
        #expect(ComposerInputChrome.verticalInset == 6)
    }

    @Test func sendButtonStaysMonochromeAcrossAppearances() {
        let light = ComposerSendButtonAppearance.colorScheme(.light)
        let dark = ComposerSendButtonAppearance.colorScheme(.dark)

        #expect(light.fill == .black)
        #expect(light.symbol == .white)
        #expect(dark.fill == .white)
        #expect(dark.symbol == .black)
    }

    @Test func voiceRecordingControlsKeepCancelAvailableAndGateStopOnLock() {
        #expect(!ComposerVoiceChromePresentation.showsCancel(isActive: false))
        #expect(ComposerVoiceChromePresentation.showsCancel(isActive: true))
        #expect(!ComposerVoiceChromePresentation.showsStop(isActive: false, isLocked: true))
        #expect(!ComposerVoiceChromePresentation.showsStop(isActive: true, isLocked: false))
        #expect(ComposerVoiceChromePresentation.showsStop(isActive: true, isLocked: true))
    }

    @Test func activeVoiceRecordingHidesButDoesNotReplaceTheFocusedTextEntry() {
        #expect(ComposerVoiceChromePresentation.textEntryOpacity(isActive: false) == 1)
        #expect(ComposerVoiceChromePresentation.textEntryOpacity(isActive: true) == 0)
    }
}
