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
@Suite(.tags(.uiHosting))
struct ToastPresentationTests {
    @Test func toastOverlayPresentsAboveModalWindows() {
        #expect(ToastOverlayPresentation.windowLevel.rawValue > UIWindow.Level.alert.rawValue)
    }

    @Test func upwardToastGestureDismissesByDistanceOrVelocity() {
        #expect(ToastDismissGesture.shouldDismiss(
            translation: -28,
            predictedEndTranslation: -28
        ))
        #expect(ToastDismissGesture.shouldDismiss(
            translation: -12,
            predictedEndTranslation: -60
        ))
        #expect(!ToastDismissGesture.shouldDismiss(
            translation: -12,
            predictedEndTranslation: -20
        ))
        #expect(!ToastDismissGesture.shouldDismiss(
            translation: 40,
            predictedEndTranslation: 60
        ))
    }
}
