import CoreImage
import SwiftUI
import Testing
import UIKit
import Vision
import XCTest
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

@MainActor
final class ProfileShareCardLocalizationTests: XCTestCase {
    func testExportUsesSelectedLanguageOnEveryRender() throws {
        for language in [AppLanguage.english, .italian, .english] {
            let image = try AppLanguage.$testCurrentOverride.withValue(language) {
                try ProfileShareCard.render(
                    accountIdHex: "sample", displayName: "Ada Lovelace", avatar: nil,
                    profileURL: "marmot://profile/npub1" + String(repeating: "q", count: 58)
                )
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US", "it-IT"]
            let cgImage = try XCTUnwrap(image.cgImage)
            try VNImageRequestHandler(cgImage: cgImage).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: " ")
            let expected = language == .italian
                ? "Sei su White Noise? Scrivimi qui."
                : "On White Noise? Message me here."
            XCTAssertTrue(text.contains(expected), "Expected \(language.rawValue) caption in: \(text)")

            let attachment = XCTAttachment(image: image)
            attachment.name = "profile-share-\(language.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
