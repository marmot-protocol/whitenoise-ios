import Contacts
import MarmotKit
import PDFKit
import SwiftUI

nonisolated struct DocumentPreviewSource: Equatable {
    let id: String
    let reference: MediaAttachmentReferenceFfi?
    let source: AttachmentHandoffSource

    init(_ item: MessageMediaAttachment) {
        id = item.id
        reference = item.reference
        source = AttachmentHandoffSource(item)
    }

    func continues(_ previous: Self, outgoing: Bool) -> Bool {
        guard id == previous.id, reference == previous.reference else { return false }
        if source == previous.source { return true }
        if outgoing, reference != nil, previous.source == .none { return true }
        if case .hint = previous.source, case .target(let target) = source { return previous.source.matches(target) }
        return false
    }
}

nonisolated enum DocumentPreviewFormat {
    case pdf, text, contact

    init?(for item: MessageMediaAttachment) {
        var type = MediaAttachmentPolicy.canonicalMediaType(item.mediaType)
        if type.isEmpty || type == "application/octet-stream",
           let ext = MediaAttachmentPolicy.safeFileExtension(from: item.fileName),
           MediaAttachmentPolicy.supportedDocumentExtensions.contains(ext) {
            type = MediaAttachmentPolicy.mediaType(forFileExtension: ext) ?? type
        }
        switch type {
        case "application/pdf": self = .pdf
        case "text/plain": self = .text
        case "text/vcard", "text/x-vcard": self = .contact
        default: return nil
        }
    }

    // Beyond these display budgets the existing file handoff can handle the attachment.
    var byteLimit: Int {
        switch self {
        case .pdf: 16 * 1024 * 1024
        case .text: 64 * 1024
        case .contact: 256 * 1024
        }
    }
}

nonisolated struct SharedContactPreview: Equatable {
    let name: String?
    let emails: [String]
    let phones: [String]

    init?(data: Data) {
        guard data.count <= DocumentPreviewFormat.contact.byteLimit,
              let contacts = try? CNContactVCardSerialization.contacts(with: data),
              contacts.count == 1, let contact = contacts.first else { return nil }
        name = ContentSanitizer.compactSingleLine(CNContactFormatter.string(from: contact, style: .fullName), maxLength: 128)
            ?? ContentSanitizer.compactSingleLine(contact.organizationName, maxLength: 128)
        emails = contact.emailAddresses.compactMap { ContentSanitizer.compactSingleLine($0.value as String, maxLength: 320) }
        phones = contact.phoneNumbers.compactMap { ContentSanitizer.compactSingleLine($0.value.stringValue, maxLength: 64) }
        guard name != nil || !emails.isEmpty || !phones.isEmpty else { return nil }
    }
}

nonisolated struct MessageDocumentPreview: Identifiable {
    enum Content {
        case pdf(PDFDocument)
        case text(String)
        case contact(SharedContactPreview)
    }

    let id = UUID()
    let content: Content

    @concurrent
    static func parse(data: Data, format: DocumentPreviewFormat) async -> sending Self? {
        guard !Task.isCancelled, data.count <= format.byteLimit else { return nil }
        switch format {
        case .pdf:
            guard let document = PDFDocument(data: data), !document.isEncrypted, document.pageCount > 0 else { return nil }
            return Self(content: .pdf(document))
        case .text:
            guard let decoded = String(data: data, encoding: .utf8) else { return nil }
            let text = ContentSanitizer.textRun(decoded)
            guard !text.isEmpty else { return nil }
            return Self(content: .text(text))
        case .contact:
            guard let card = SharedContactPreview(data: data) else { return nil }
            return Self(content: .contact(card))
        }
    }
}

@MainActor @Observable
final class DocumentSharePresentation {
    var file: AttachmentShareFile?
    private(set) var control: MediaFileTransferControlFfi?

    /// Prefer an in-app preview and hand off the original slot when it cannot be displayed.
    func openDocument(_ item: MessageMediaAttachment, using loader: ConversationMediaLoader, demand: AttachmentDemand,
                      isCurrent: () -> Bool, didReadSize: (Int?) -> Void) async throws -> MessageDocumentPreview? {
        let format = DocumentPreviewFormat(for: item)
        if let format {
            var requested = item
            requested.previewByteLimit = format.byteLimit
            do {
                let data = try await loader.data(for: requested, demand: demand)
                guard isCurrent() else { throw CancellationError() }
                didReadSize(data.count)
                if let preview = await MessageDocumentPreview.parse(data: data, format: format) {
                    guard isCurrent() else { throw CancellationError() }
                    return preview
                }
            } catch AttachmentReadError.previewLimitExceeded(let size) {
                guard isCurrent() else { throw CancellationError() }
                didReadSize(size)
            }
        }
        guard isCurrent() else { throw CancellationError() }
        // The bounded read already used this tap’s retry for a missing original slot.
        // A rejected or oversized preview hands off with ordinary open semantics.
        try await present(item, using: loader, demand: format == nil ? demand : .explicit, isCurrent: isCurrent)
        return nil
    }

    func present(_ item: MessageMediaAttachment, using loader: ConversationMediaLoader, demand: AttachmentDemand,
                 isCurrent: () -> Bool = { true }) async throws {
        guard control == nil else { return }
        let request = MediaFileTransferControlFfi()
        control = request
        defer { if control === request { control = nil } }
        let opened = try await loader.shareFile(for: item, demand: demand, control: request)
        do {
            guard control === request, !request.isCancelled(), isCurrent() else { throw CancellationError() }
            guard try await loader.canShareDocument(item, opened.lease?.target) else { throw AttachmentReadError.unavailable }
            guard control === request, !request.isCancelled(), !Task.isCancelled, isCurrent() else { throw CancellationError() }
            file = opened
        } catch {
            opened.finish()
            throw error
        }
    }

    func close() {
        control?.cancel()
        control = nil
        file?.finish()
        file = nil
    }
}

private final class ConversationPDFView: PDFView, PDFViewDelegate {
    func pdfViewWillClick(onLink sender: PDFView, with url: URL) {}

    // The attachment viewer handles navigation within the displayed document.
    override func perform(_ action: PDFAction) {
        if action is PDFActionGoTo { super.perform(action) }
    }
}

private struct DocumentPDFView: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let view = ConversationPDFView()
        view.delegate = view
        view.autoScales = true
        view.document = document
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {}
}

struct MessageDocumentPreviewSheet: View {
    let preview: MessageDocumentPreview
    let item: MessageMediaAttachment
    let loader: ConversationMediaLoader
    @Environment(\.dismiss) private var dismiss
    @State private var share = DocumentSharePresentation()
    @State private var shareFailed = false

    var body: some View {
        NavigationStack {
            Group {
                switch preview.content {
                case .pdf(let document):
                    DocumentPDFView(document: document)
                case .text(let text):
                    ScrollView {
                        Text(verbatim: text).frame(maxWidth: .infinity, alignment: .leading).padding()
                    }
                case .contact(let contact):
                    List {
                        if let name = contact.name { Text(verbatim: name).font(.headline) }
                        ForEach(Array(contact.emails.enumerated()), id: \.offset) { _, value in
                            Label { Text(verbatim: value) } icon: { Image(systemName: "envelope") }
                        }
                        ForEach(Array(contact.phones.enumerated()), id: \.offset) { _, value in
                            Label { Text(verbatim: value) } icon: { Image(systemName: "phone") }
                        }
                    }
                }
            }
            .navigationTitle(item.fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task {
                            do {
                                try await share.present(item, using: loader, demand: .userTap(afterFailure: shareFailed))
                                shareFailed = false
                            } catch is CancellationError {
                            } catch AttachmentHandoffFailure.storageFull {
                                // The existing handoff path presents storage guidance.
                            } catch { shareFailed = true }
                        }
                    } label: {
                        if share.control != nil { ProgressView() }
                        else { Label("Share", systemImage: "square.and.arrow.up") }
                    }
                    .disabled(share.control != nil)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if shareFailed { Text("Attachment couldn’t be read").font(.footnote).padding() }
            }
            .sheet(item: $share.file) { file in
                ActivityShareSheet(items: [file.url], onComplete: file.finish)
                    .onDisappear(perform: file.finish)
            }
        }
        .onDisappear { share.close() }
    }
}
