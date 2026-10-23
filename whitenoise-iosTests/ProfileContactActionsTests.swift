import SwiftUI
import Testing
import UIKit
@testable import whitenoise_ios

@MainActor
struct ProfileContactActionsTests {
    @Test(arguments: [ColorScheme.light, .dark])
    func contactActionsRenderWithNeutralColors(colorScheme: ColorScheme) throws {
        let view = ProfileContactActions(contactName: "Ren", onMessage: {}, onNewGroup: {}, onAddToGroup: {})
            .frame(width: 350).padding(16)
            .background(Color(uiColor: .systemGroupedBackground))
            .environment(\.colorScheme, colorScheme)
        let renderer = ImageRenderer(content: view)
        let image = try #require(renderer.cgImage)
        // Catch a button accidentally inheriting the system blue tint.
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let coloredPixels = stride(from: 0, to: pixels.count, by: 4).filter { index in
            Int(pixels[index + 2]) - Int(pixels[index]) > 35
        }.count
        #expect(coloredPixels == 0)
    }
}
