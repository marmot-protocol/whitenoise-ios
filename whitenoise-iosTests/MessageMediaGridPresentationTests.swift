import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

struct MessageMediaGridPresentationTests {

    @Test func gridShowsAtMostFiveTilesAndCountsHiddenAttachments() {
        #expect(MessageMediaGridPresentation.visibleCount(totalCount: 1) == 1)
        #expect(MessageMediaGridPresentation.visibleCount(totalCount: 4) == 4)
        #expect(MessageMediaGridPresentation.visibleCount(totalCount: 6) == 5)
        #expect(MessageMediaGridPresentation.hiddenCount(totalCount: 4) == 0)
        #expect(MessageMediaGridPresentation.hiddenCount(totalCount: 6) == 1)
    }

    @Test func gridUsesSingleTileOneRowOrTwoByTwoLayouts() {
        #expect(MessageMediaGridPresentation.columnCount(totalCount: 1) == 1)
        #expect(MessageMediaGridPresentation.rowCount(totalCount: 1) == 1)
        #expect(MessageMediaGridPresentation.columnCount(totalCount: 2) == 2)
        #expect(MessageMediaGridPresentation.rowCount(totalCount: 2) == 1)
        #expect(MessageMediaGridPresentation.columnCount(totalCount: 3) == 2)
        #expect(MessageMediaGridPresentation.rowCount(totalCount: 3) == 2)
        #expect(MessageMediaGridPresentation.columnCount(totalCount: 10) == 2)
        #expect(MessageMediaGridPresentation.rowCount(totalCount: 10) == 3)
    }

    @Test func galleryCompositionMatchesDesignedTwoThreeAndFiveItemFrames() {
        let two = MessageMediaGridPresentation.layout(totalCount: 2, maxWidth: 256)
        #expect(two.size == CGSize(width: 256, height: 127))
        #expect(two.frames == [
            CGRect(x: 0, y: 0, width: 127, height: 127),
            CGRect(x: 129, y: 0, width: 127, height: 127),
        ])

        let three = MessageMediaGridPresentation.layout(totalCount: 3, maxWidth: 256)
        #expect(three.size == CGSize(width: 256, height: 170))
        #expect(three.frames == [
            CGRect(x: 0, y: 0, width: 170, height: 170),
            CGRect(x: 172, y: 0, width: 84, height: 84),
            CGRect(x: 172, y: 86, width: 84, height: 84),
        ])

        let overflow = MessageMediaGridPresentation.layout(totalCount: 7, maxWidth: 256)
        #expect(overflow.size == CGSize(width: 256, height: 213))
        #expect(overflow.frames.count == 5)
        #expect(overflow.overflowCount == 2)
    }

    @Test func galleryCompositionScalesToTheAvailableBubbleWidth() {
        let layout = MessageMediaGridPresentation.layout(totalCount: 2, maxWidth: 128)
        #expect(layout.size == CGSize(width: 128, height: 63.5))
        #expect(layout.frames[0] == CGRect(x: 0, y: 0, width: 63.5, height: 63.5))
        #expect(layout.frames[1] == CGRect(x: 64.5, y: 0, width: 63.5, height: 63.5))
    }

    @Test func gridRoundsOnlyOuterTileCorners() {
        let single = MessageMediaGridPresentation.roundedCorners(totalCount: 1, tileIndex: 0)
        #expect(single.topLeading)
        #expect(single.topTrailing)
        #expect(single.bottomLeading)
        #expect(single.bottomTrailing)

        let leadingTile = MessageMediaGridPresentation.roundedCorners(totalCount: 2, tileIndex: 0)
        #expect(leadingTile.topLeading)
        #expect(!leadingTile.topTrailing)
        #expect(leadingTile.bottomLeading)
        #expect(!leadingTile.bottomTrailing)

        let trailingTile = MessageMediaGridPresentation.roundedCorners(totalCount: 2, tileIndex: 1)
        #expect(!trailingTile.topLeading)
        #expect(trailingTile.topTrailing)
        #expect(!trailingTile.bottomLeading)
        #expect(trailingTile.bottomTrailing)

        let bottomRight = MessageMediaGridPresentation.roundedCorners(totalCount: 4, tileIndex: 3)
        #expect(!bottomRight.topLeading)
        #expect(!bottomRight.topTrailing)
        #expect(!bottomRight.bottomLeading)
        #expect(bottomRight.bottomTrailing)

        let sparseBottomLeft = MessageMediaGridPresentation.roundedCorners(totalCount: 3, tileIndex: 2)
        #expect(!sparseBottomLeft.topLeading)
        #expect(!sparseBottomLeft.topTrailing)
        #expect(sparseBottomLeft.bottomLeading)
        #expect(sparseBottomLeft.bottomTrailing)

        let sparseEmptySlot = MessageMediaGridPresentation.roundedCorners(totalCount: 3, tileIndex: 3)
        #expect(!sparseEmptySlot.hasRoundedCorners)

        let negativeIndex = MessageMediaGridPresentation.roundedCorners(totalCount: 3, tileIndex: -1)
        #expect(!negativeIndex.hasRoundedCorners)
    }

    @Test func semanticGridCornersMirrorForRightToLeftLayout() {
        let leadingCorners = MessageMediaTileCornerRadii(
            topLeading: true,
            topTrailing: false,
            bottomLeading: true,
            bottomTrailing: false
        )
        let trailingCorners = MessageMediaTileCornerRadii(
            topLeading: false,
            topTrailing: true,
            bottomLeading: false,
            bottomTrailing: true
        )

        let leadingLeftToRight = leadingCorners.uiRectCorners(layoutDirection: .leftToRight)
        #expect(leadingLeftToRight.contains(.topLeft))
        #expect(leadingLeftToRight.contains(.bottomLeft))
        #expect(!leadingLeftToRight.contains(.topRight))
        #expect(!leadingLeftToRight.contains(.bottomRight))

        let leadingRightToLeft = leadingCorners.uiRectCorners(layoutDirection: .rightToLeft)
        #expect(!leadingRightToLeft.contains(.topLeft))
        #expect(!leadingRightToLeft.contains(.bottomLeft))
        #expect(leadingRightToLeft.contains(.topRight))
        #expect(leadingRightToLeft.contains(.bottomRight))

        let trailingLeftToRight = trailingCorners.uiRectCorners(layoutDirection: .leftToRight)
        #expect(!trailingLeftToRight.contains(.topLeft))
        #expect(!trailingLeftToRight.contains(.bottomLeft))
        #expect(trailingLeftToRight.contains(.topRight))
        #expect(trailingLeftToRight.contains(.bottomRight))

        let trailingRightToLeft = trailingCorners.uiRectCorners(layoutDirection: .rightToLeft)
        #expect(trailingRightToLeft.contains(.topLeft))
        #expect(trailingRightToLeft.contains(.bottomLeft))
        #expect(!trailingRightToLeft.contains(.topRight))
        #expect(!trailingRightToLeft.contains(.bottomRight))
    }
}
