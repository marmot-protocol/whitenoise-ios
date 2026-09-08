import CoreGraphics
import Foundation
import Testing
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
}

struct WNPhotoMenuPlacementTests {
    private let container = CGSize(width: 402, height: 874)

    private func origin(anchor: CGRect, hasPhoto: Bool = true, in size: CGSize? = nil) -> CGPoint {
        WNPhotoMenuMetrics.panelOrigin(
            anchor: anchor,
            panelHeight: WNPhotoMenuMetrics.panelHeight(hasPhoto: hasPhoto),
            container: size ?? container
        )
    }

    @Test func removeRowAddsItsOwnDividerToTheHeight() {
        let withoutPhoto = WNPhotoMenuMetrics.panelHeight(hasPhoto: false)
        let withPhoto = WNPhotoMenuMetrics.panelHeight(hasPhoto: true)
        #expect(withoutPhoto == 3 * WNPhotoMenuMetrics.rowHeight)
        #expect(withPhoto == withoutPhoto + WNPhotoMenuMetrics.rowHeight + 1)
    }

    @Test func opensBelowTheAnchorCenteredOnIt() {
        let anchor = CGRect(x: 151, y: 300, width: 100, height: 44)
        let placed = origin(anchor: anchor)

        #expect(placed.y == anchor.maxY + WNPhotoMenuMetrics.anchorGap)
        #expect(placed.x + WNPhotoMenuMetrics.menuWidth / 2 == anchor.midX)
    }

    @Test func staysInsideTheContainerForAnchorsNearAnEdge() {
        for anchor in [
            CGRect(x: 0, y: 300, width: 60, height: 44),
            CGRect(x: 342, y: 300, width: 60, height: 44),
        ] {
            let placed = origin(anchor: anchor)
            #expect(placed.x >= WNPhotoMenuMetrics.screenMargin)
            #expect(
                placed.x + WNPhotoMenuMetrics.menuWidth
                    <= container.width - WNPhotoMenuMetrics.screenMargin
            )
        }
    }

    @Test func flipsAboveTheAnchorWhenItWouldNotFitBelow() {
        let anchor = CGRect(x: 151, y: 780, width: 100, height: 44)
        let placed = origin(anchor: anchor)
        let height = WNPhotoMenuMetrics.panelHeight(hasPhoto: true)

        #expect(placed.y + height < anchor.minY)
        #expect(placed.y == anchor.minY - WNPhotoMenuMetrics.anchorGap - height)
    }

    @Test func keepsThePanelAtItsButtonWhenTheContainerIsDegenerate() {
        // A fullScreenCover presented from inside a sheet reports a zero-size
        // GeometryReader; clamping against that put the panel in the corner.
        let anchor = CGRect(x: 151, y: 300, width: 100, height: 44)
        let placed = origin(anchor: anchor, in: .zero)

        #expect(placed.y == anchor.maxY + WNPhotoMenuMetrics.anchorGap)
        #expect(placed.x + WNPhotoMenuMetrics.menuWidth / 2 == anchor.midX)
    }

    @Test func neverPlacesThePanelOffTheTopWhenNothingFits() {
        let tiny = CGSize(width: 402, height: 200)
        let placed = origin(anchor: CGRect(x: 151, y: 150, width: 100, height: 44), in: tiny)
        #expect(placed.y >= WNPhotoMenuMetrics.screenMargin)
    }
}
