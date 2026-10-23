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
