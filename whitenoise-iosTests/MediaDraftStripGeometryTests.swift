import SwiftUI
import Testing
import UIKit
@testable import whitenoise_ios

/// A square composer tile cropped every portrait and panorama to 1:1, so the
/// draft never previewed the shape it would send. Sizing each tile from its own
/// aspect ratio restores that, and the width bounds are what keep a portrait
/// from collapsing to a sliver next to a panorama in the same shelf.
struct ComposerMediaDraftPreviewWidthTests {
    @Test func aSquareDraftKeepsTheShelfHeightAsItsWidth() {
        let width = ComposerMediaDraftLayout.visualPreviewWidth(
            dim: "800x800",
            thumbnailSize: nil
        )

        #expect(width == ComposerMediaDraftLayout.visualPreviewHeight)
    }

    @Test func aLandscapeDraftIsWiderThanAPortraitDraft() {
        let landscape = ComposerMediaDraftLayout.visualPreviewWidth(
            dim: "1600x900",
            thumbnailSize: nil
        )
        let portrait = ComposerMediaDraftLayout.visualPreviewWidth(
            dim: "900x1600",
            thumbnailSize: nil
        )

        #expect(landscape > ComposerMediaDraftLayout.visualPreviewHeight)
        #expect(portrait < ComposerMediaDraftLayout.visualPreviewHeight)
        #expect(landscape > portrait)
    }

    @Test func extremeShapesClampToTheShelfWidthBounds() {
        let panorama = ComposerMediaDraftLayout.visualPreviewWidth(
            dim: "4000x500",
            thumbnailSize: nil
        )
        let sliver = ComposerMediaDraftLayout.visualPreviewWidth(
            dim: "500x4000",
            thumbnailSize: nil
        )

        #expect(panorama == ComposerMediaDraftLayout.maximumVisualPreviewWidth)
        #expect(sliver == ComposerMediaDraftLayout.minimumVisualPreviewWidth)
        #expect(panorama < sliver * 2)
    }

    @Test func aDraftWithoutDimensionsFallsBackToItsThumbnailShape() {
        let width = ComposerMediaDraftLayout.visualPreviewWidth(
            dim: nil,
            thumbnailSize: CGSize(width: 120, height: 100)
        )

        #expect(width == ComposerMediaDraftLayout.visualPreviewWidth(
            dim: "1200x1000",
            thumbnailSize: nil
        ))
        #expect(width > ComposerMediaDraftLayout.visualPreviewHeight)
        #expect(width < ComposerMediaDraftLayout.maximumVisualPreviewWidth)
    }

    @Test func aDraftWithNothingToMeasureRendersSquare() {
        let bounds = [
            ComposerMediaDraftLayout.visualPreviewWidth(dim: nil, thumbnailSize: nil),
            ComposerMediaDraftLayout.visualPreviewWidth(dim: "bad", thumbnailSize: nil),
            ComposerMediaDraftLayout.visualPreviewWidth(dim: "0x0", thumbnailSize: nil),
            ComposerMediaDraftLayout.visualPreviewWidth(
                dim: nil,
                thumbnailSize: CGSize(width: 0, height: 120)
            ),
            ComposerMediaDraftLayout.visualPreviewWidth(
                dim: nil,
                thumbnailSize: CGSize(width: CGFloat.nan, height: CGFloat.nan)
            ),
        ]

        #expect(bounds.allSatisfy { $0 == ComposerMediaDraftLayout.visualPreviewHeight })
    }

    @Test func anUnusableAspectRatioStaysInsideTheRequestedBounds() {
        let width = ComposerMediaDraftLayout.visualPreviewWidth(
            aspectRatio: .infinity,
            height: 44,
            minimumWidth: 32,
            maximumWidth: 72
        )

        #expect(width == 44)
    }

    @Test func invertedBoundsStillProduceAFiniteWidth() {
        let width = ComposerMediaDraftLayout.visualPreviewWidth(
            aspectRatio: 4,
            height: 100,
            minimumWidth: 150,
            maximumWidth: 50
        )

        #expect(width == 150)
    }
}

@MainActor
struct MediaDraftStripGeometryTests {
    @Test func theShelfGrowsWiderForALandscapeDraftThanAPortraitOne() {
        let panorama = renderedStrip([draft(dim: "4000x500", thumbnail: CGSize(width: 400, height: 50))])
        let portrait = renderedStrip([draft(dim: "400x1200", thumbnail: CGSize(width: 40, height: 120))])
        let square = renderedStrip([draft(dim: "800x800", thumbnail: CGSize(width: 80, height: 80))])

        #expect(panorama.width > square.width)
        #expect(square.width > portrait.width)
        #expect(panorama.height == square.height)
        #expect(portrait.height == square.height)
    }

    @Test func aVisualDraftTileIsItsAspectWidthInsideTheShelfPadding() {
        let rendered = renderedStrip([draft(dim: "1600x900", thumbnail: CGSize(width: 160, height: 90))])

        #expect(rendered.width == ComposerMediaDraftLayout.visualPreviewWidth(
            dim: "1600x900",
            thumbnailSize: nil
        ) + (ComposerMediaDraftLayout.shelfPadding * 2))
        #expect(rendered.height == ComposerMediaDraftLayout.visualPreviewHeight
            + (ComposerMediaDraftLayout.shelfPadding * 2))
    }

    @Test func aDraftWithoutDimensionsOrAThumbnailRendersTheSquareTile() {
        let unknown = renderedStrip([draft(dim: nil, thumbnail: nil)])
        let square = renderedStrip([draft(dim: "800x800", thumbnail: nil)])

        #expect(unknown == square)
    }

    @Test func aStripOfMixedShapesGrowsByEachDraftsOwnWidth() {
        let shapes = ["4000x500", "400x1200", "800x800"]
        let one = renderedStrip([draft(dim: shapes[0], thumbnail: nil)])
        let three = renderedStrip(shapes.map { draft(dim: $0, thumbnail: nil) })

        let addedWidth = shapes.dropFirst().reduce(0) { total, dim in
            total + ComposerMediaDraftLayout.visualPreviewWidth(dim: dim, thumbnailSize: nil)
                + ComposerMediaDraftLayout.itemSpacing
        }
        #expect(three.width == one.width + addedWidth)
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
