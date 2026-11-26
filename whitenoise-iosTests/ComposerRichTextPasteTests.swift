import Testing
import UIKit
import UniformTypeIdentifiers
@testable import whitenoise_ios

@Suite
struct ComposerRichTextPasteTests {
    @Test func takesImageAndCaptionFromANotesStyleSelection() throws {
        let rtfd = try Self.rtfd(attachments: [Self.png()], trailingText: "\nSunset at the pier\n")

        let content = try #require(ComposerRichTextPaste.content(rtfd: rtfd, maxImageBytes: .max))

        #expect(content.images.count == 1)
        #expect(content.text == "Sunset at the pier")
    }

    @Test func takesEveryEmbeddedImage() throws {
        let rtfd = try Self.rtfd(attachments: [Self.png(), Self.png()], trailingText: "")

        let content = try #require(ComposerRichTextPaste.content(rtfd: rtfd, maxImageBytes: .max))

        #expect(content.images.count == 2)
        #expect(content.text == nil)
    }

    @Test func skipsImagesOverTheSourceLimitBeforeDecoding() throws {
        let png = Self.png()
        let rtfd = try Self.rtfd(attachments: [png], trailingText: "Caption")

        #expect(ComposerRichTextPaste.content(rtfd: rtfd, maxImageBytes: png.count - 1) == nil)
        #expect(ComposerRichTextPaste.content(rtfd: rtfd, maxImageBytes: png.count) != nil)
    }

    @Test func leavesTextOnlyAndUnreadableRichTextToTheSystemPaste() throws {
        let textOnly = try Self.rtfd(attachments: [], trailingText: "Just words")

        #expect(ComposerRichTextPaste.content(rtfd: textOnly, maxImageBytes: .max) == nil)
        #expect(ComposerRichTextPaste.content(rtfd: Data("not rtfd".utf8), maxImageBytes: .max) == nil)
    }

    private static func png() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    private static func rtfd(attachments: [Data], trailingText: String) throws -> Data {
        let string = NSMutableAttributedString()
        for data in attachments {
            string.append(NSAttributedString(attachment: NSTextAttachment(data: data, ofType: UTType.png.identifier)))
        }
        string.append(NSAttributedString(string: trailingText))
        return try string.data(
            from: NSRange(location: 0, length: string.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        )
    }
}
