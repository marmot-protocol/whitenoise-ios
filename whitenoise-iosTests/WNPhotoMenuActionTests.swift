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
    @Test func sourceSymbolsStayNeutralWhenTheNativeHostUsesBlueTint() throws {
        for scheme in [ColorScheme.light, .dark] {
            for action in WNPhotoMenuAction.available(hasPhoto: false) {
                let view = UIImageView(image: action.symbol(for: scheme))
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
                let opaque = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0 + 3] == 255 }
                #expect(!opaque.isEmpty)
                for offset in opaque {
                    #expect(pixels[offset] == pixels[offset + 1])
                    #expect(pixels[offset] == pixels[offset + 2])
                    #expect(scheme == .dark ? pixels[offset] > 245 : pixels[offset] < 10)
                }
            }
        }
    }
}
