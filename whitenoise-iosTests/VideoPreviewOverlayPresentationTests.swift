import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

struct VideoPreviewOverlayPresentationTests {

    @Test func draftVideoPreviewUsesReadableCompactOverlay() {
        let diameter = VideoPreviewOverlayPresentation.diameter(for: CGSize(width: 68, height: 68))

        #expect(diameter == VideoPreviewOverlayPresentation.compactDiameter)
        #expect(VideoPreviewOverlayPresentation.iconFontSize(for: diameter) >= 19)
    }

    @Test func messageVideoPreviewUsesLargeCenteredOverlay() {
        let diameter = VideoPreviewOverlayPresentation.diameter(for: CGSize(width: 300, height: 169))

        #expect(diameter == VideoPreviewOverlayPresentation.regularDiameter)
    }

    @Test func veryLargeVideoPreviewCapsOverlayDiameter() {
        let diameter = VideoPreviewOverlayPresentation.diameter(for: CGSize(width: 600, height: 400))

        #expect(diameter == VideoPreviewOverlayPresentation.maximumDiameter)
    }
}
