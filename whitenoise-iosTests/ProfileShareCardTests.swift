import CoreImage
import SwiftUI
import Testing
import UIKit
@testable import whitenoise_ios

@MainActor
struct ProfileShareCardTests {
    @Test(arguments: ["Ada Lovelace", String(repeating: "Long profile name ", count: 8), "أهلاً بالعالم"])
    func exportedCardContainsScannableProfileURL(name: String) throws {
        let payload = "marmot://profile/npub1" + String(repeating: "q", count: 58)
        let image = try ProfileShareCard.render(
            accountIdHex: "sample", displayName: name, avatar: nil, profileURL: payload
        )
        #expect(image.cgImage?.width == 1440)
        #expect(image.cgImage?.height == 1620)
        let detector = try #require(CIDetector(
            ofType: CIDetectorTypeQRCode, context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        ))
        let ciImage = try #require(CIImage(image: image))
        let messages = detector.features(in: ciImage).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        #expect(messages.contains(payload))
    }
}
