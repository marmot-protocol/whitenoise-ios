import CoreGraphics
import Testing
@testable import whitenoise_ios

struct DetailsQuickActionsGridLayoutTests {
    private func columns(_ widths: [CGFloat], in available: CGFloat) -> Int {
        DetailsQuickActionsGridLayout.columnCount(
            itemWidths: widths,
            availableWidth: available,
            spacing: 12,
            maximumColumns: 2
        )
    }

    @Test func labelsThatFitTwoAcrossGetTwoColumns() {
        #expect(columns([80, 120, 90, 100], in: 370) == 2)
    }

    @Test func oneLabelTooWideForHalfTheRowDropsToOneColumn() {
        #expect(columns([80, 400, 90], in: 370) == 1)
    }

    @Test func labelsMayShrinkToTheirMinimumScaleBeforeTheGridNarrows() {
        let halfRow: CGFloat = (370 - 12) / 2
        let shrinkable = halfRow / DetailsQuickActionsGridLayout.labelMinimumScaleFactor
        #expect(columns([80, shrinkable - 1], in: 370) == 2)
        #expect(columns([80, shrinkable + 1], in: 370) == 1)
    }

    @Test func neverMoreColumnsThanItemsOrTheMaximum() {
        #expect(columns([40], in: 1_000) == 1)
        #expect(DetailsQuickActionsGridLayout.columnCount(
            itemWidths: [40, 40, 40, 40],
            availableWidth: 1_000,
            spacing: 12,
            maximumColumns: 3
        ) == 3)
        #expect(columns([], in: 370) == 1)
    }
}
