import CoreImage
import SwiftUI
import Testing
import UIKit
@testable import whitenoise_ios

struct WNQRCodeCardMetricsTests {
    private static let legacyFixedCardWidth: CGFloat = 225 + 2 * 16
    private static let formContainerWidth: CGFloat = 369

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
    private static func prototypeSymbolWidth(forContainerWidth containerWidth: CGFloat) -> CGFloat {
        containerWidth * 0.81 - 24
    }
}

@MainActor
@Suite(.serialized, .tags(.uiHosting))
struct WNQRCodeCardRenderingTests {
    private static let payload = "marmot://profile/npub1" + String(repeating: "q", count: 58)
    private static let containerWidth: CGFloat = 369
    private static let renderScale: CGFloat = 3

    // 320 is the narrowest container and leaves the tightest quiet zone.
    @Test(arguments: [CGFloat(320), 369])
    func theRenderedCardDecodesBackToItsPayload(containerWidth: CGFloat) throws {
        let card = try Self.renderCard(image: QRCode.image(from: Self.payload), containerWidth: containerWidth)

        #expect(Self.decodedPayloads(in: card).contains(Self.payload))
    }

    @Test(arguments: [CGFloat(320), 369])
    func theRenderedCardKeepsAFullQuietZoneAroundTheSymbol(containerWidth: CGFloat) throws {
        let bare = try #require(QRCode.image(from: Self.payload, scale: 1, quietZoneModules: 0))
        let moduleCount = bare.size.width

        let card = try Self.renderCard(image: QRCode.image(from: Self.payload), containerWidth: containerWidth)
        let bitmap = try #require(Self.bitmap(of: card))
        let symbol = try #require(bitmap.horizontalExtent { $0 <= 100 }, "no symbol rendered")
        let surface = try #require(bitmap.horizontalExtent { $0 >= 250 }, "no card rendered")

        let module = CGFloat(symbol.upperBound - symbol.lowerBound + 1) / moduleCount
        let margin = CGFloat(
            min(symbol.lowerBound - surface.lowerBound, surface.upperBound - symbol.upperBound)
        )

        #expect(
            margin + 1 >= module * QRCode.standardQuietZoneModules,
            "container \(containerWidth) left \(margin / module) modules of quiet zone"
        )
    }

    @Test func theCardKeepsTheSameSquareWhileTheImageIsStillLoading() throws {
        let loading = try #require(Self.bitmap(of: Self.renderCard(image: nil)))
        let loaded = try #require(
            Self.bitmap(of: Self.renderCard(image: QRCode.image(from: Self.payload)))
        )
        let isCard: (UInt8) -> Bool = { $0 >= 250 }

        let loadingRect = try #require(loading.horizontalExtent(where: isCard))
        let loadedRect = try #require(loaded.horizontalExtent(where: isCard))
        let loadingHeight = try #require(loading.verticalExtent(where: isCard))
        let loadedHeight = try #require(loaded.verticalExtent(where: isCard))

        #expect(loadingRect == loadedRect, "width \(loadingRect) loading, \(loadedRect) loaded")
        #expect(loadingHeight == loadedHeight, "height \(loadingHeight) loading, \(loadedHeight) loaded")
        #expect(
            abs((loadedRect.upperBound - loadedRect.lowerBound)
                - (loadedHeight.upperBound - loadedHeight.lowerBound)) <= 3,
            "card is not square: \(loadedRect) by \(loadedHeight)"
        )
    }

    @Test func theFailureKeepsTheSameQRCodeCard() throws {
        let readyImage = try Self.renderCard(image: QRCode.image(from: Self.payload))
        let failedImage = try Self.renderCard(
            image: nil,
            unavailableDescription: "You can still share your profile link from the Share menu."
        )
        let ready = try #require(Self.bitmap(of: readyImage))
        let failed = try #require(Self.bitmap(of: failedImage))
        let isWhiteCard: (UInt8) -> Bool = { $0 >= 250 }
        let readyWidth = try #require(ready.horizontalExtent(where: isWhiteCard))
        let readyHeight = try #require(ready.verticalExtent(where: isWhiteCard))
        #expect(failed.horizontalExtent(where: isWhiteCard) == readyWidth)
        #expect(failed.verticalExtent(where: isWhiteCard) == readyHeight)
        #expect(Self.decodedPayloads(in: readyImage).contains(Self.payload))
        #expect(Self.decodedPayloads(in: failedImage).isEmpty)
    }

    /// Hosts the card in a window and renders its layer tree. The short run
    /// loop turn lets SwiftUI commit the card before rendering; the suite is
    /// `.serialized`. `drawHierarchy(afterScreenUpdates:)` was tried instead
    /// and lost part of the quiet zone on the Xcode 26 CI simulator.
    private static func renderCard(
        image: UIImage?,
        unavailableDescription: LocalizedStringKey? = nil,
        containerWidth: CGFloat = Self.containerWidth
    ) throws -> UIImage {
        let controller = UIHostingController(
            rootView: WNQRCodeCard(
                image: image,
                accessibilityLabel: "Profile QR code",
                unavailableDescription: unavailableDescription
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
