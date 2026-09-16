import UIKit
import CoreImage.CIFilterBuiltins

/// Generates QR code images from strings using CoreImage. No camera or
/// permissions involved — this is the *encode* side.
enum QRCode {
    private static let context = CIContext()

    static func image(
        from string: String,
        scale: CGFloat = 12,
        removesQuietZone: Bool = false
    ) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let symbol = removesQuietZone ? croppedToSymbol(output) : output
        let scaled = symbol.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    private static func croppedToSymbol(_ image: CIImage) -> CIImage {
        let symbolExtent = image.extent.insetBy(dx: 1, dy: 1)
        guard !symbolExtent.isEmpty else { return image }
        return image
            .cropped(to: symbolExtent)
            .transformed(
                by: CGAffineTransform(translationX: -symbolExtent.minX, y: -symbolExtent.minY)
            )
    }
}
