import Foundation
import SwiftUI
import Testing
import UIKit
@testable import whitenoise_ios

struct WNPhotoMenuActionTests {

    @Test func offersOnlySourcesWithoutAPhoto() {
        #expect(
            WNPhotoMenuAction.available(hasPhoto: false)
                == [.chooseFromPhotos, .chooseFromFiles, .findImageOnWeb]
        )
    }

    @Test func appendsRemoveLastWhenAPhotoExists() {
        #expect(
            WNPhotoMenuAction.available(hasPhoto: true)
                == [.chooseFromPhotos, .chooseFromFiles, .findImageOnWeb, .removePhoto]
        )
    }

    @Test func removeIsTheOnlyDestructiveAction() {
        let destructive = WNPhotoMenuAction.allCases.filter(\.isDestructive)
        #expect(destructive == [.removePhoto])
    }

    @Test func everyActionHasASymbol() {
        for action in WNPhotoMenuAction.allCases {
            #expect(!action.systemImage.isEmpty)
        }
    }

    @MainActor
    @Test func destructiveSymbolUsesTheCurrentContrastVariant() throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(traitsFrom: [
                UITraitCollection(userInterfaceStyle: style),
                UITraitCollection(accessibilityContrast: .high)
            ])
            let expected = try #require(UIImage(systemName: "trash"))
                .withTintColor(UIColor.systemRed.resolvedColor(with: traits), renderingMode: .alwaysOriginal)
            traits.performAsCurrent {
                let actual = WNPhotoMenuAction.removePhoto.symbol(for: style == .dark ? .dark : .light, contrast: .increased)
                #expect(actual.pngData() == expected.pngData())
            }
        }
    }

    @MainActor
    @Test func sourceSymbolsStayNeutralWhenTheNativeHostUsesBlueTint() throws {
        for contrast in [ColorSchemeContrast.standard, .increased] {
            for scheme in [ColorScheme.light, .dark] {
                for action in WNPhotoMenuAction.available(hasPhoto: false) {
                    let pixels = try opaquePixels(of: action.symbol(for: scheme, contrast: contrast))
                    #expect(!pixels.isEmpty)
                    for pixel in pixels {
                        #expect(pixel.red == pixel.green)
                        #expect(pixel.red == pixel.blue)
                        #expect(scheme == .dark ? pixel.red > 245 : pixel.red < 10)
                    }
                }
            }
        }
    }

    @MainActor
    private func opaquePixels(of symbol: UIImage) throws -> [(red: UInt8, green: UInt8, blue: UInt8)] {
        let view = UIImageView(image: symbol)
        view.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        view.contentMode = .center
        view.tintColor = .systemBlue
        let rendered = UIGraphicsImageRenderer(size: view.bounds.size).image { context in
            view.layer.render(in: context.cgContext)
        }
        let image = try #require(rendered.cgImage)
        var pixels = [UInt8](repeating: 0, count: 44 * 44 * 4)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: &pixels, width: 44, height: 44, bitsPerComponent: 8, bytesPerRow: 44 * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 44, height: 44))
        var opaque: [(red: UInt8, green: UInt8, blue: UInt8)] = []
        for offset in stride(from: 0, to: pixels.count, by: 4) where pixels[offset + 3] == 255 {
            opaque.append((red: pixels[offset], green: pixels[offset + 1], blue: pixels[offset + 2]))
        }
        return opaque
    }
}
