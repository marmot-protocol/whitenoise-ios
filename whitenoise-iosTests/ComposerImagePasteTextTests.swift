import Foundation
import Testing
@testable import whitenoise_ios

@Suite
struct ComposerImagePasteTextTests {
    @Test func keepsCaptionCopiedAlongsideAnImage() {
        #expect(ComposerImagePasteText.text(string: "Sunset at the pier", url: nil) == "Sunset at the pier")
    }

    @Test func pastesNothingExtraForAnImageAlone() {
        #expect(ComposerImagePasteText.text(string: nil, url: nil) == nil)
        #expect(ComposerImagePasteText.text(string: " \n", url: nil) == nil)
    }

    @Test func dropsAttachmentPlaceholdersFromRichSelections() {
        #expect(ComposerImagePasteText.text(string: "\u{FFFC}", url: nil) == nil)
        #expect(ComposerImagePasteText.text(string: "Before\u{FFFC} after", url: nil) == "Before after")
    }

    @Test func dropsBlankLinesLeftByARemovedPlaceholder() {
        #expect(ComposerImagePasteText.text(string: "\u{FFFC}\nCaption\n", url: nil) == "Caption")
    }

    @Test func skipsTheImageSourceLinkWhenItIsTheOnlyText() throws {
        let url = try #require(URL(string: "https://example.com/photo.jpg"))
        #expect(ComposerImagePasteText.text(string: "https://example.com/photo.jpg", url: url) == nil)
        #expect(ComposerImagePasteText.text(string: "See https://example.com/photo.jpg", url: url) != nil)
    }
}
