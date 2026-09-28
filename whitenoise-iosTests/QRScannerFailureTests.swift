import AVFoundation
import Testing
@testable import whitenoise_ios

struct QRScannerFailureTests {
    @Test func interruptionsExplainTheConditionThatMustChangeBeforeRetry() {
        let busy = QRScannerFailure.interruption(reason: AVCaptureSession.InterruptionReason.videoDeviceInUseByAnotherClient.rawValue)
        let multitasking = QRScannerFailure.interruption(reason: AVCaptureSession.InterruptionReason.videoDeviceNotAvailableWithMultipleForegroundApps.rawValue)
        #expect(busy == .cameraInUse)
        #expect(multitasking == .requiresFullScreen)
        #expect(busy.recovery == .retry)
        #expect(multitasking.recovery == .retry)
        #expect(QRScannerFailure.interruption(reason: nil) == .interrupted)
        #expect(QRScannerFailure.interruption(reason: nil).recovery == .retry)
        #expect(QRScannerFailure.interruption(reason: Int.max) == .interrupted)
    }

    @Test(arguments: [true, false])
    func deniedPermissionOffersSettingsEvenWhenCameraDiscoveryFails(hasCamera: Bool) {
        let failure = QRScannerFailure.preflight(authorization: .denied, hasCamera: hasCamera)
        #expect(failure == .denied)
        #expect(failure?.recovery == .settings)
    }

    @Test(arguments: [true, false])
    func restrictionsNeverOfferSettingsOrRetry(hasCamera: Bool) {
        let failure = QRScannerFailure.preflight(authorization: .restricted, hasCamera: hasCamera)
        #expect(failure == .restricted)
        #expect(failure?.recovery == QRScannerFailure.Recovery.none)
    }

    @Test(arguments: [AVAuthorizationStatus.authorized, .notDetermined])
    func missingHardwareDoesNotOfferAnIneffectiveRetry(authorization: AVAuthorizationStatus) {
        let failure = QRScannerFailure.preflight(authorization: authorization, hasCamera: false)
        #expect(failure == .noCamera)
        #expect(failure?.recovery == QRScannerFailure.Recovery.none)
        #expect(QRScannerFailure.preflight(authorization: authorization, hasCamera: true) == nil)
    }
}
