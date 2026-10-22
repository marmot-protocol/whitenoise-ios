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
struct ToastPresentationTests {
    @Test func toastOverlayPresentsAboveModalWindows() {
        #expect(ToastOverlayPresentation.windowLevel.rawValue > UIWindow.Level.alert.rawValue)
    }

    @Test func toastDefaultsStayVisibleLongEnoughToRead() {
        #expect(Toast.success("Saved").duration == 3.0)
        #expect(Toast.warning("Warning").duration == 3.5)
        #expect(Toast.error("Failed").duration == 4.0)
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
