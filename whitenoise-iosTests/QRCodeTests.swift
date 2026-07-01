import CoreImage
import Testing
import UIKit
@testable import whitenoise_ios

struct QRCodeTests {
    @Test func generatesNonEmptyImageForString() throws {
        let image = try #require(QRCode.image(from: "whitenoise:npub1example"))

        #expect(image.size.width > 0)
        #expect(image.size.height > 0)
    }

    @Test func generatedImageDecodesBackToInput() throws {
        let payload = "whitenoise:npub1exampleexample123"
        let image = try #require(QRCode.image(from: payload))
        let ciImage = try #require(CIImage(image: image))
        let detector = CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        )
        let decoded = (detector?.features(in: ciImage) ?? [])
            .compactMap { ($0 as? CIQRCodeFeature)?.messageString }

        #expect(decoded.contains(payload))
    }
}
