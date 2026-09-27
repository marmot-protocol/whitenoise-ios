import AVFoundation
import Testing
@testable import whitenoise_ios

struct QRScannerFailureTests {
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
