import UIKit
import CoreImage.CIFilterBuiltins

/// Generates QR code images from strings using CoreImage. No camera or
/// permissions involved — this is the *encode* side.
enum QRCode {
    static let standardQuietZoneModules: CGFloat = 4

    private static let context = CIContext()

    static func image(
        from string: String,
        scale: CGFloat = 12,
        quietZoneModules: CGFloat = QRCode.standardQuietZoneModules
    ) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let symbolExtent = output.extent.insetBy(dx: 1, dy: 1)
        guard !symbolExtent.isEmpty else { return nil }
        let symbol = output
            .cropped(to: symbolExtent)
            .transformed(
                by: CGAffineTransform(translationX: -symbolExtent.minX, y: -symbolExtent.minY)
            )
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let rendered = context.createCGImage(symbol, from: symbol.extent) else { return nil }
        return inset(rendered, byQuietZone: quietZoneModules * scale)
    }

    private static func inset(_ symbol: CGImage, byQuietZone quietZone: CGFloat) -> UIImage {
        let side = CGFloat(symbol.width) + 2 * quietZone
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(
            size: CGSize(width: side, height: side),
            format: format
        ).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            context.cgContext.interpolationQuality = .none
            context.cgContext.draw(
                symbol,
                in: CGRect(
                    x: quietZone,
                    y: quietZone,
                    width: CGFloat(symbol.width),
                    height: CGFloat(symbol.height)
                )
            )
        }
    }
}
