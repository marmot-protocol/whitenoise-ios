import CoreImage
import Testing
import UIKit
@testable import whitenoise_ios

struct QRCodeTests {
    private static let profilePayload = "marmot://profile/npub1" + String(repeating: "q", count: 58)

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

    @Test func theQuietZoneIsRenderedIntoTheImage() throws {
        let scale: CGFloat = 10
        let bare = try #require(
            QRCode.image(from: Self.profilePayload, scale: scale, quietZoneModules: 0)
        )
        let zoned = try #require(QRCode.image(from: Self.profilePayload, scale: scale))

        let grown = 2 * QRCode.standardQuietZoneModules * scale
        #expect(zoned.size.width == bare.size.width + grown)
        #expect(zoned.size.height == bare.size.height + grown)
    }

    @Test func theQuietZoneScalesWithTheSymbol() throws {
        let small = try #require(QRCode.image(from: Self.profilePayload, scale: 4))
        let large = try #require(QRCode.image(from: Self.profilePayload, scale: 20))

        #expect(large.size.width == small.size.width * 5)
    }

    @Test func aBareSymbolStillDecodesWhenTheCallerSuppliesNoZone() throws {
        let bare = try #require(
            QRCode.image(from: Self.profilePayload, scale: 10, quietZoneModules: 0)
        )
        let onWhite = try #require(Self.composited(bare, onSurroundOf: 40, color: .white))

        #expect(Self.decodedPayloads(in: onWhite).contains(Self.profilePayload))
    }

    @Test func theImageDecodesAgainstASurroundItDoesNotControl() throws {
        let image = try #require(QRCode.image(from: Self.profilePayload, scale: 10))
        let onGrey = try #require(Self.composited(image, onSurroundOf: 40, color: .gray))

        #expect(Self.decodedPayloads(in: onGrey).contains(Self.profilePayload))
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

    private static func composited(
        _ image: UIImage,
        onSurroundOf margin: CGFloat,
        color: CIColor
    ) -> CIImage? {
        guard let symbol = CIImage(image: image) else { return nil }
        let cardExtent = symbol.extent.insetBy(dx: -margin, dy: -margin)
        let card = CIImage(color: color).cropped(to: cardExtent)
        return symbol
            .composited(over: card)
            .transformed(
                by: CGAffineTransform(translationX: -cardExtent.minX, y: -cardExtent.minY)
            )
    }
}
