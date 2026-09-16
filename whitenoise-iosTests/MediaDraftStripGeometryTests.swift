import SwiftUI
import Testing
import UIKit
@testable import whitenoise_ios

/// The composer strip used to size each tile from the photo's own aspect ratio,
/// so a portrait collapsed to a sliver next to a panorama. These lock the tile
/// to one footprint regardless of what the picker hands us.
@MainActor
struct MediaDraftStripGeometryTests {
    @Test func everyVisualDraftRendersTheSameTileWhateverTheSourceShape() {
        let panorama = renderedStrip([draft(dim: "4000x500", thumbnail: CGSize(width: 400, height: 50))])
        let portrait = renderedStrip([draft(dim: "400x1200", thumbnail: CGSize(width: 40, height: 120))])
        let square = renderedStrip([draft(dim: "800x800", thumbnail: CGSize(width: 80, height: 80))])

        #expect(panorama == portrait)
        #expect(portrait == square)
    }

    @Test func aVisualDraftTileIsTheFixedPreviewSizeInsideTheShelfPadding() {
        let expectedSide = ComposerMediaDraftLayout.previewSize.width
            + (ComposerMediaDraftLayout.shelfPadding * 2)

        let rendered = renderedStrip([draft(dim: "1600x900", thumbnail: CGSize(width: 160, height: 90))])

        #expect(rendered.width == expectedSide)
        #expect(rendered.height == ComposerMediaDraftLayout.previewSize.height
            + (ComposerMediaDraftLayout.shelfPadding * 2))
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

    @Test func aDocumentOnlyStripKeepsTheShorterUtilityRow() {
        let rendered = renderedStrip([
            MediaDraftAttachment(
                fileName: "brief.pdf",
                mediaType: "application/pdf",
                data: Data([1]),
                dim: nil
            ),
        ])

        #expect(rendered.height == ComposerMediaDraftLayout.utilityPreviewHeight
            + (ComposerMediaDraftLayout.shelfPadding * 2))
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
