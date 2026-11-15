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
    @Test func composerControlsClearTheAppleMinimumTapTarget() {
        #expect(ComposerInputChrome.controlSize >= 44)
    }

    @MainActor
    @Test(arguments: [ColorScheme.light, .dark])
    func sendButtonSymbolStaysLegibleOnItsFill(_ scheme: ColorScheme) {
        let appearance = ComposerSendButtonAppearance.colorScheme(scheme)
        let ratio = ContrastProbe.ratio(
            foreground: appearance.symbol.color,
            background: appearance.fill.color,
            style: scheme == .dark ? .dark : .light
        )

        #expect(ratio >= 4.5, "send symbol contrast \(ratio) in \(scheme)")
    }

    @Test func voiceRecordingControlsKeepCancelAvailableAndGateStopOnLock() {
        #expect(!ComposerVoiceChromePresentation.showsCancel(isActive: false))
        #expect(ComposerVoiceChromePresentation.showsCancel(isActive: true))
        #expect(!ComposerVoiceChromePresentation.showsStop(isActive: false, isLocked: true))
        #expect(!ComposerVoiceChromePresentation.showsStop(isActive: true, isLocked: false))
        #expect(ComposerVoiceChromePresentation.showsStop(isActive: true, isLocked: true))
    }

    /// A draft that fills mid-hold must not swap out the view carrying the hold.
    @Test func sendButtonWaitsForTheVoiceHoldToEnd() {
        #expect(ComposerVoiceChromePresentation.showsSend(hasSendableContent: true, isActive: false))
        #expect(!ComposerVoiceChromePresentation.showsSend(hasSendableContent: true, isActive: true))
        #expect(!ComposerVoiceChromePresentation.showsSend(hasSendableContent: false, isActive: false))
    }

    @Test func activeVoiceRecordingHidesButDoesNotReplaceTheFocusedTextEntry() {
        #expect(ComposerVoiceChromePresentation.textEntryOpacity(isActive: false) == 1)
        #expect(ComposerVoiceChromePresentation.textEntryOpacity(isActive: true) == 0)
    }
}
