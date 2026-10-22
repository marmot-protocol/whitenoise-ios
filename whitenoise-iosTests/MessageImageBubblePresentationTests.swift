import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

struct MessageImageBubblePresentationTests {

    @Test func mediaOnlyPortraitBubbleWrapsRenderedImageWidth() {
        let renderedSize = MessageImageBubblePresentation.displaySize(
            maxWidth: 300,
            dim: "1080x1920"
        )

        #expect(MessageRichMediaBubblePresentation.contentWidth(
            maxWidth: 300,
            singleVisualWidth: renderedSize.width,
            hasCaption: false,
            hasReply: false
        ) == renderedSize.width)
    }

    @Test func captionOrReplyKeepsRichMediaBubbleReadable() {
        #expect(MessageRichMediaBubblePresentation.contentWidth(
            maxWidth: 300,
            singleVisualWidth: 228,
            hasCaption: true,
            hasReply: false
        ) == 300)
        #expect(MessageRichMediaBubblePresentation.contentWidth(
            maxWidth: 300,
            singleVisualWidth: 228,
            hasCaption: false,
            hasReply: true
        ) == 300)
    }

    @Test func landscapeImageUsesActualAspectRatio() {
        let size = MessageImageBubblePresentation.displaySize(maxWidth: 300, dim: "640x360")

        #expect(size.width == 300)
        #expect(size.height == 169)
    }

    @Test func portraitImageNarrowsAndCapsItsHeight() {
        let size = MessageImageBubblePresentation.displaySize(maxWidth: 300, dim: "1080x1920")

        #expect(size.width == 228)
        #expect(size.height == 405)
    }

    @Test func captionedPortraitImageFillsTheBubbleMediaWidth() {
        let size = MessageImageBubblePresentation.displaySize(
            maxWidth: 300,
            dim: "1080x1920",
            fillsWidth: true
        )

        #expect(size.width == 300)
        #expect(size.height == 405)
    }

    @Test func captionedLandscapeImageKeepsItsUnfilledSize() {
        let filled = MessageImageBubblePresentation.displaySize(
            maxWidth: 300,
            dim: "640x360",
            fillsWidth: true
        )

        #expect(filled == MessageImageBubblePresentation.displaySize(maxWidth: 300, dim: "640x360"))
    }

    @Test func captionedShallowPortraitImageNeedsNoCrop() {
        let filled = MessageImageBubblePresentation.displaySize(
            maxWidth: 300,
            dim: "900x1000",
            fillsWidth: true
        )

        #expect(filled == MessageImageBubblePresentation.displaySize(maxWidth: 300, dim: "900x1000"))
        #expect(filled == CGSize(width: 300, height: 333))
    }

    @Test func captionOrReplyMakesTheSingleVisualFillTheBubble() {
        #expect(MessageRichMediaBubblePresentation.singleVisualFillsBubbleWidth(
            hasCaption: false,
            hasReply: false
        ) == false)
        #expect(MessageRichMediaBubblePresentation.singleVisualFillsBubbleWidth(
            hasCaption: true,
            hasReply: false
        ))
        #expect(MessageRichMediaBubblePresentation.singleVisualFillsBubbleWidth(
            hasCaption: false,
            hasReply: true
        ))
    }

    @Test func missingOrMalformedImageDimensionsUseSquareFallback() {
        #expect(MessageImageBubblePresentation.displaySize(maxWidth: 300, dim: nil) == CGSize(width: 300, height: 300))
        #expect(MessageImageBubblePresentation.displaySize(maxWidth: 300, dim: "bad") == CGSize(width: 300, height: 300))
        #expect(MessageImageBubblePresentation.displaySize(maxWidth: 300, dim: "0x400") == CGSize(width: 300, height: 300))
    }

    @Test func extremeImageDimensionsAreClamped() {
        #expect(MessageImageBubblePresentation.aspectRatio(dim: "10000x1") == 4)
        #expect(MessageImageBubblePresentation.aspectRatio(dim: "1x10000") == 0.25)
    }
}
