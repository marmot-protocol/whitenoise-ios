import CoreImage
import SwiftUI
import Testing
import UIKit
@testable import whitenoise_ios

struct WNQRCodeCardMetricsTests {
    private static let legacyFixedCardWidth: CGFloat = 225 + 2 * 16
    private static let formContainerWidth: CGFloat = 369

    @Test func cardWidthScalesWithItsContainer() {
        let narrow = WNQRCodeCard.Metrics.width(forContainerWidth: 320)
        let wide = WNQRCodeCard.Metrics.width(forContainerWidth: 440)

        #expect(narrow < wide)
        #expect(narrow == 320 * WNQRCodeCard.Metrics.widthFraction)
        #expect(wide == 440 * WNQRCodeCard.Metrics.widthFraction)
    }

    @Test func cardNeverOutgrowsItsContainer() {
        for containerWidth in [CGFloat(320), 369, 402, 440, 700] {
            #expect(WNQRCodeCard.Metrics.width(forContainerWidth: containerWidth) < containerWidth)
        }
    }

    @Test func cardIsLargerThanTheFixedSizeItReplaced() {
        let width = WNQRCodeCard.Metrics.width(forContainerWidth: Self.formContainerWidth)

        #expect(width > Self.legacyFixedCardWidth)
    }

    @Test func theCardLeavesRoomForTheQuietZoneOutsideTheSymbol() {
        let width = WNQRCodeCard.Metrics.width(forContainerWidth: Self.formContainerWidth)

        #expect(width > Self.prototypeSymbolWidth(forContainerWidth: Self.formContainerWidth))
    }

    /// The width the symbol had before the quiet zone was rendered into the
    /// image: the card's old 0.81 share less its 12-point margins.
    static func prototypeSymbolWidth(forContainerWidth containerWidth: CGFloat) -> CGFloat {
        containerWidth * 0.81 - 24
    }
}

@MainActor
@Suite(.serialized)
struct WNQRCodeCardRenderingTests {
    private static let payload = "marmot://profile/npub1" + String(repeating: "q", count: 58)
    private static let containerWidths: [CGFloat] = [320, 369, 402, 440]
    private static let renderScale: CGFloat = 3

    @Test func theRenderedCardDecodesBackToItsPayload() throws {
        for containerWidth in Self.containerWidths {
            let card = try Self.renderCard(containerWidth: containerWidth)

            #expect(
                Self.decodedPayloads(in: card).contains(Self.payload),
                "no decode at container width \(containerWidth)"
            )
        }
    }

    @Test func theRenderedCardKeepsAFullQuietZoneAroundTheSymbol() throws {
        let bare = try #require(QRCode.image(from: Self.payload, scale: 1, quietZoneModules: 0))
        let moduleCount = bare.size.width

        for containerWidth in Self.containerWidths {
            let card = try Self.renderCard(containerWidth: containerWidth)
            let bitmap = try #require(Self.bitmap(of: card))
            let symbol = try #require(
                bitmap.horizontalExtent { $0 <= 100 },
                "no symbol rendered at container width \(containerWidth)"
            )
            let surface = try #require(
                bitmap.horizontalExtent { $0 >= 250 },
                "no card rendered at container width \(containerWidth)"
            )

            let module = CGFloat(symbol.upperBound - symbol.lowerBound + 1) / moduleCount
            let margin = CGFloat(
                min(symbol.lowerBound - surface.lowerBound, surface.upperBound - symbol.upperBound)
            )

            #expect(
                margin + 1 >= module * QRCode.standardQuietZoneModules,
                "container \(containerWidth) left \(margin / module) modules of quiet zone"
            )
        }
    }

    @Test func theCardKeepsTheSameSquareWhileTheImageIsStillLoading() throws {
        for containerWidth in Self.containerWidths {
            let loading = try #require(
                Self.bitmap(of: Self.renderCard(containerWidth: containerWidth, image: nil))
            )
            let loaded = try #require(
                Self.bitmap(of: Self.renderCard(containerWidth: containerWidth))
            )
            let isCard: (UInt8) -> Bool = { $0 >= 250 }

            let loadingRect = try #require(loading.horizontalExtent(where: isCard))
            let loadedRect = try #require(loaded.horizontalExtent(where: isCard))
            let loadingHeight = try #require(loading.verticalExtent(where: isCard))
            let loadedHeight = try #require(loaded.verticalExtent(where: isCard))

            #expect(
                loadingRect == loadedRect,
                "container \(containerWidth) width \(loadingRect) loading, \(loadedRect) loaded"
            )
            #expect(
                loadingHeight == loadedHeight,
                "container \(containerWidth) height \(loadingHeight) loading, \(loadedHeight) loaded"
            )
            #expect(
                abs((loadedRect.upperBound - loadedRect.lowerBound)
                    - (loadedHeight.upperBound - loadedHeight.lowerBound)) <= 3,
                "container \(containerWidth) card is not square: \(loadedRect) by \(loadedHeight)"
            )
        }
    }

    @Test func theSymbolKeepsTheSizeItHadInThePrototype() throws {
        for containerWidth in Self.containerWidths {
            let card = try #require(Self.bitmap(of: Self.renderCard(containerWidth: containerWidth)))
            let symbol = try #require(card.horizontalExtent { $0 <= 100 })
            let width = CGFloat(symbol.upperBound - symbol.lowerBound + 1) / Self.renderScale
            let prototype = WNQRCodeCardMetricsTests
                .prototypeSymbolWidth(forContainerWidth: containerWidth)

            #expect(
                abs(width - prototype) <= 6,
                "container \(containerWidth) symbol \(width)pt, prototype \(prototype)pt"
            )
        }
    }

    private static func renderCard(
        containerWidth: CGFloat,
        image: UIImage? = QRCode.image(from: payload)
    ) throws -> UIImage {
        let controller = UIHostingController(
            rootView: WNQRCodeCard(
                image: image,
                accessibilityLabel: "Profile QR code"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemGroupedBackground))
        )
        controller.safeAreaRegions = []
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let bounds = CGRect(x: 0, y: 0, width: containerWidth, height: containerWidth)
        let window = UIWindow(windowScene: scene)
        window.frame = bounds
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.frame = bounds
        controller.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = renderScale
        return UIGraphicsImageRenderer(bounds: bounds, format: format).image { context in
            window.layer.render(in: context.cgContext)
        }
    }

    private static func decodedPayloads(in image: UIImage) -> [String] {
        guard let ciImage = CIImage(image: image) else { return [] }
        let detector = CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        )
        return (detector?.features(in: ciImage) ?? [])
            .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }

    private struct Bitmap {
        let width: Int
        let height: Int
        let luma: [UInt8]

        func verticalExtent(where matches: (UInt8) -> Bool) -> ClosedRange<Int>? {
            var lowest = Int.max
            var highest = Int.min
            for y in 0..<height {
                let row = y * width
                for x in 0..<width where matches(luma[row + x]) {
                    lowest = min(lowest, y)
                    highest = max(highest, y)
                    break
                }
            }
            return lowest <= highest ? lowest...highest : nil
        }

        func horizontalExtent(where matches: (UInt8) -> Bool) -> ClosedRange<Int>? {
            var lowest = Int.max
            var highest = Int.min
            for y in 0..<height {
                let row = y * width
                for x in 0..<width where matches(luma[row + x]) {
                    lowest = min(lowest, x)
                    highest = max(highest, x)
                }
            }
            return lowest <= highest ? lowest...highest : nil
        }
    }

    private static func bitmap(of image: UIImage) -> Bitmap? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        var luma = [UInt8](repeating: 0, count: width * height)
        let drawn = luma.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? Bitmap(width: width, height: height, luma: luma) : nil
    }
}

struct WNNeutralAccentTests {
    @Test func accentIsMonochromeInLightAppearance() {
        #expect(WNNeutralAccent.color(for: .light) == .black)
    }

    @Test func accentIsMonochromeInDarkAppearance() {
        #expect(WNNeutralAccent.color(for: .dark) == .white)
    }

    @Test func accentNeverFallsBackToTheSystemTint() {
        #expect(WNNeutralAccent.color(for: .light) != .accentColor)
        #expect(WNNeutralAccent.color(for: .dark) != .accentColor)
    }
}

struct CopyableValueChipFeedbackTests {
    @Test func offersACopyGlyphBeforeCopying() {
        #expect(CopyableValueChip.Feedback.symbolName(isCopied: false) == "doc.on.doc")
    }

    @Test func confirmsWithACheckmarkAfterCopying() {
        #expect(CopyableValueChip.Feedback.symbolName(isCopied: true) == "checkmark")
    }

    @Test func accessibilityLabelNamesTheValueBeforeCopying() {
        let label = CopyableValueChip.Feedback.accessibilityLabel(isCopied: false, valueName: "npub")

        #expect(label.contains("npub"))
        #expect(label != L10n.string("Copied"))
    }

    @Test func accessibilityLabelConfirmsTheCopyAfterwards() {
        let label = CopyableValueChip.Feedback.accessibilityLabel(isCopied: true, valueName: "npub")

        #expect(label == L10n.string("Copied"))
    }

    @Test func copyFeedbackResetsAfterABoundedDelay() {
        #expect(CopyableValueChip.Feedback.resetDelay > .zero)
        #expect(CopyableValueChip.Feedback.resetDelay <= .seconds(5))
    }
}
