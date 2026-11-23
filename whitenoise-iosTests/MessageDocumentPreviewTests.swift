import Foundation
import MarmotKit
import Observation
import PDFKit
import Synchronization
import Testing
import UIKit
@testable import whitenoise_ios

@MainActor
struct MessageDocumentPreviewTests {
    @Test func anOpenDocumentSurvivesSendConfirmationAndClosesWhenTheKnownSourceIsReplaced() throws {
        let reference = MediaAttachmentReferenceFfi(locators: [], ciphertextSha256: "", plaintextSha256: "report",
            nonceHex: "", fileName: "Report.pdf", mediaType: "application/pdf", version: .v1, sourceEpoch: 1, dim: nil, thumbhash: nil)
        var item = try #require(MessageMediaAttachment.displayItems(from: [reference], ownerId: "outgoing").first)
        let pending = DocumentPreviewSource(item)
        item.localTarget = .init(messageIdHex: "message", sourceMessageIdHex: "first", attachmentIndex: 0)
        let confirmed = DocumentPreviewSource(item)
        #expect(confirmed.continues(pending, outgoing: true))
        #expect(!confirmed.continues(pending, outgoing: false))
        item.localTarget?.sourceMessageIdHex = "replacement"
        #expect(!DocumentPreviewSource(item).continues(confirmed, outgoing: true))
    }

    @Test func pdfPreviewShowsReadablePagesAndHandsOffFilesThatNeedAnOpeningPassword() async throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 120, height: 120))
        let pdf = renderer.pdfData { context in context.beginPage() }
        #expect(await MessageDocumentPreview.parse(data: pdf, format: .pdf) != nil)
        let document = try #require(PDFDocument(data: pdf))
        let readable = try #require(document.dataRepresentation(options: [
            PDFDocumentWriteOption.userPasswordOption: "", PDFDocumentWriteOption.ownerPasswordOption: "owner"
        ]))
        let ownerProtected = try #require(PDFDocument(data: readable))
        #expect(ownerProtected.isEncrypted && !ownerProtected.isLocked)
        #expect(await MessageDocumentPreview.parse(data: readable, format: .pdf) != nil)
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

    @Test func textPreviewRejectsInvalidUTF8AndOversizedInput() async {
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

    @Test func documentRuntimeScopeNotifiesObserversWhenRuntimeSuspendsOrChangesAccountOrPhase() async throws {
        let appState = AppState.test()
        appState.setPhase(.ready)
        appState.activeAccountRef = "account-a"

        func expectObservedChange(_ mutation: () async throws -> Void) async rethrows {
            let before = DocumentRuntimeScope(appState)
            let notified = Mutex(false)
            withObservationTracking {
                _ = DocumentRuntimeScope(appState)
            } onChange: {
                notified.withLock { $0 = true }
            }
            try await mutation()
            #expect(notified.withLock { $0 })
            #expect(DocumentRuntimeScope(appState) != before)
        }

        await expectObservedChange {
            appState.activeAccountRef = "account-b"
        }
        await expectObservedChange {
            appState.setPhase(.bootstrapping)
        }
        try await expectObservedChange {
            try await appState.runtimeLifecycle.closeForAppErasure()
        }
    }
}
