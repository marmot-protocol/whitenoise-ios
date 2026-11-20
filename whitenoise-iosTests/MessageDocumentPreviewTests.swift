import Foundation
import PDFKit
import Testing
import UIKit
@testable import whitenoise_ios

@MainActor
struct MessageDocumentPreviewTests {
    @Test func encryptedPDFStaysOnTheOriginalFileHandoff() async throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 120, height: 120))
        let pdf = renderer.pdfData { context in context.beginPage() }
        #expect(await MessageDocumentPreview.parse(data: pdf, format: .pdf) != nil)
        let document = try #require(PDFDocument(data: pdf))
        let protected = try #require(document.dataRepresentation(options: [
            PDFDocumentWriteOption.userPasswordOption: "viewer", PDFDocumentWriteOption.ownerPasswordOption: "owner"
        ]))
        #expect(await MessageDocumentPreview.parse(data: protected, format: .pdf) == nil)
    }

    @Test func textPreviewStripsDirectionalOverridesAndPreservesLayout() async throws {
        let bytes = Data("line one\n\tline\u{202e} two".utf8)
        let preview = try #require(await MessageDocumentPreview.parse(data: bytes, format: .text))
        guard case .text(let text) = preview.content else {
            Issue.record("Expected a text preview")
            return
        }
        #expect(text == "line one\n\tline two")
    }

    @Test func sharesTheOriginalWhenTextCannotBeShownWithinThePreviewBudget() async {
        #expect(await MessageDocumentPreview.parse(data: Data([0xff, 0xc0]), format: .text) == nil)
        let oversized = Data(repeating: 65, count: DocumentPreviewFormat.text.byteLimit + 1)
        #expect(await MessageDocumentPreview.parse(data: oversized, format: .text) == nil)
    }

    @Test func aMultiContactCardDoesNotPresentOnlyTheFirstPerson() throws {
        let card = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Avery Stone\r\nN:Stone;Avery;;;\r\nEMAIL:avery@example.invalid\r\nEND:VCARD\r\n"
        let preview = try #require(SharedContactPreview(data: Data(card.utf8)))
        #expect(preview.name?.contains("Avery") == true)
        #expect(preview.emails == ["avery@example.invalid"])
        let second = card.replacingOccurrences(of: "Avery", with: "Robin")
        #expect(SharedContactPreview(data: Data((card + second).utf8)) == nil)
    }
}
