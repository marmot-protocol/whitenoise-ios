import SwiftUI
import Testing
@testable import whitenoise_ios

struct QRScannerScenePolicyTests {
    @Test func cameraStaysMountedUnderSystemOverlaysAndUnmountsInBackground() {
        #expect(QRScannerScenePolicy.mountsCamera(in: .active))
        #expect(QRScannerScenePolicy.mountsCamera(in: .inactive))
        #expect(!QRScannerScenePolicy.mountsCamera(in: .background))
    }

    @Test func previewIsCoveredWheneverTheSceneIsNotActive() {
        #expect(!QRScannerScenePolicy.coversPreview(in: .active))
        #expect(QRScannerScenePolicy.coversPreview(in: .inactive))
        #expect(QRScannerScenePolicy.coversPreview(in: .background))
    }

    @Test func onlyReturningFromBackgroundRestartsAFailedScanner() {
        #expect(QRScannerScenePolicy.restartsScanner(leavingPhase: .background, showingFailure: true))
        #expect(!QRScannerScenePolicy.restartsScanner(leavingPhase: .background, showingFailure: false))
        #expect(!QRScannerScenePolicy.restartsScanner(leavingPhase: .inactive, showingFailure: true))
        #expect(!QRScannerScenePolicy.restartsScanner(leavingPhase: .active, showingFailure: true))
    }
}
