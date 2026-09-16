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

        #expect(Self.decodedPayloads(in: image).contains(payload))
    }

    @Test func quietZoneRemovalTrimsOneModuleFromEveryEdge() throws {
        let payload = "marmot://profile/npub1exampleexample123"
        let scale: CGFloat = 10
        let padded = try #require(QRCode.image(from: payload, scale: scale))
        let trimmed = try #require(
            QRCode.image(from: payload, scale: scale, removesQuietZone: true)
        )

        #expect(trimmed.size.width == padded.size.width - 2 * scale)
        #expect(trimmed.size.height == padded.size.height - 2 * scale)
    }

    @Test func quietZoneRemovalKeepsTheCodeScannableOnAPaddedCard() throws {
        let payload = "marmot://profile/npub1exampleexample123"
        let scale: CGFloat = 10
        let trimmed = try #require(
            QRCode.image(from: payload, scale: scale, removesQuietZone: true)
        )
        let onCard = try #require(Self.composited(trimmed, onLightMarginOf: scale * 4))

        #expect(Self.decodedPayloads(in: onCard).contains(payload))
    }

    private static func decodedPayloads(in image: UIImage) -> [String] {
        guard let ciImage = CIImage(image: image) else { return [] }
        return decodedPayloads(in: ciImage)
    }

    private static func decodedPayloads(in image: CIImage) -> [String] {
        let detector = CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        )
        return (detector?.features(in: image) ?? [])
            .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }

    private static func composited(_ image: UIImage, onLightMarginOf margin: CGFloat) -> CIImage? {
        guard let symbol = CIImage(image: image) else { return nil }
        let cardExtent = symbol.extent.insetBy(dx: -margin, dy: -margin)
        let card = CIImage(color: .white).cropped(to: cardExtent)
        return symbol
            .composited(over: card)
            .transformed(
                by: CGAffineTransform(translationX: -cardExtent.minX, y: -cardExtent.minY)
            )
    }
}
