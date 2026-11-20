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
        #expect(VideoPreviewOverlayPresentation.iconFontSize(for: VideoPreviewOverlayPresentation.compactDiameter) >= 19)
    }
}
