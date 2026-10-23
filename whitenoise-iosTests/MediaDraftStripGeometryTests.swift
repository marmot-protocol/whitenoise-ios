import SwiftUI
import Testing
import UIKit
@testable import whitenoise_ios

/// The composer strip used to size each tile from the photo's own aspect ratio,
/// so a portrait collapsed to a sliver next to a panorama. These lock the tile
/// to one footprint regardless of what the picker hands us.
@MainActor
@Suite(.tags(.uiHosting))
struct MediaDraftStripGeometryTests {
    @Test func everyVisualDraftRendersTheSameTileWhateverTheSourceShape() {
        let panorama = renderedStrip([draft(dim: "4000x500", thumbnail: CGSize(width: 400, height: 50))])
        let portrait = renderedStrip([draft(dim: "400x1200", thumbnail: CGSize(width: 40, height: 120))])
        let square = renderedStrip([draft(dim: "800x800", thumbnail: CGSize(width: 80, height: 80))])

        #expect(panorama == portrait)
        #expect(portrait == square)
    }

    @Test func aDraftWithoutDimensionsOrAThumbnailStillRendersTheSameTile() {
        let known = renderedStrip([draft(dim: "1600x900", thumbnail: CGSize(width: 160, height: 90))])
        let unknown = renderedStrip([draft(dim: nil, thumbnail: nil)])

        #expect(known == unknown)
    }

    @Test func aStripOfMixedShapesGrowsByOneTileWidthPerDraft() {
        let one = renderedStrip([draft(dim: "4000x500", thumbnail: nil)])
        let three = renderedStrip([
            draft(dim: "4000x500", thumbnail: nil),
            draft(dim: "400x1200", thumbnail: nil),
            draft(dim: "800x800", thumbnail: nil),
        ])

        let perDraft = ComposerMediaDraftLayout.previewSize.width + ComposerMediaDraftLayout.itemSpacing
        #expect(three.width == one.width + (perDraft * 2))
        #expect(three.height == one.height)
    }

    private func draft(dim: String?, thumbnail: CGSize?) -> MediaDraftAttachment {
        MediaDraftAttachment(
            fileName: "photo.jpg",
            mediaType: "image/jpeg",
            data: Data([0xFF, 0xD8]),
            dim: dim,
            thumbnail: thumbnail.map { size in
                UIGraphicsImageRenderer(size: size).image { context in
                    UIColor.systemTeal.setFill()
                    context.fill(CGRect(origin: .zero, size: size))
                }
            }
        )
    }

    private func renderedStrip(_ attachments: [MediaDraftAttachment]) -> CGSize {
        let renderer = ImageRenderer(
            content: MediaDraftStrip(
                attachments: attachments,
                onRemove: { _ in },
                onPreviewVisual: { _ in }
            )
        )
        renderer.scale = 1
        return renderer.uiImage?.size ?? .zero
    }
}
