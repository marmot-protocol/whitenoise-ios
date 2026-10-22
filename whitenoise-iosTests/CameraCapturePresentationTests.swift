import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

struct CameraCapturePresentationTests {
    @Test func recordingDurationUsesMinuteAndZeroPaddedSecondFields() {
        #expect(CameraCapturePresentation.durationLabel(0) == "0:00")
        #expect(CameraCapturePresentation.durationLabel(9.99) == "0:09")
        #expect(CameraCapturePresentation.durationLabel(65) == "1:05")
        #expect(CameraCapturePresentation.durationLabel(-2) == "0:00")
    }
}
