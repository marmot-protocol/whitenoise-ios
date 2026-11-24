import Foundation
import ImageIO
@preconcurrency import AVFoundation
import CryptoKit
import MarmotKit
import Synchronization
import UIKit
import UniformTypeIdentifiers

nonisolated enum MediaAttachmentKind: String, Sendable {
    case image
    case video
    case audio
    case document
    case unsupported

    static func classify(mediaType: String, fileName: String? = nil) -> MediaAttachmentKind {
        let canonical = MediaAttachmentPolicy.canonicalMediaType(mediaType)
        if MediaAttachmentPolicy.isDecodableImageMediaType(canonical) { return .image }
        if canonical.hasPrefix("video/") { return .video }
        if canonical.hasPrefix("audio/") { return .audio }
        if MediaAttachmentPolicy.supportedDocumentMediaTypes.contains(canonical) {
            return .document
        }
        if let fileExtension = MediaAttachmentPolicy.safeFileExtension(from: fileName),
           MediaAttachmentPolicy.supportedDocumentExtensions.contains(fileExtension)
        {
            return .document
        }
        return .unsupported
    }

    var systemImageName: String {
        switch self {
        case .image: "photo"
        case .video: "play.rectangle"
        case .audio: "waveform"
        case .document: "doc.text"
        case .unsupported: "doc"
        }
    }
}

nonisolated enum MediaAttachmentPolicy {
    static let supportedAudioMediaTypes: Set<String> = [
        "audio/aac",
        "audio/mp4",
        "audio/mpeg",
        "audio/wav",
        "audio/x-m4a",
        "audio/x-wav",
    ]

    static let supportedVideoMediaTypes: Set<String> = [
        "video/mp4",
        "video/quicktime",
    ]

    static let supportedDocumentMediaTypes: Set<String> = [
        "application/json",
        "application/msword",
        "application/pdf",
        "application/rtf",
        "application/vnd.ms-excel",
        "application/vnd.ms-powerpoint",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "application/x-yaml",
        "application/x-zip-compressed",
        "application/xml",
        "application/yaml",
        "application/zip",
        "text/csv",
        "text/html",
        "text/json",
        "text/markdown",
        "text/plain",
        "text/rtf",
        "text/vcard",
        "text/x-markdown",
        "text/x-yaml",
        "text/xml",
        "text/yaml",
    ]

    static let supportedDocumentExtensions: Set<String> = [
        "csv",
        "doc",
        "docx",
        "htm",
        "html",
        "json",
        "markdown",
        "md",
        "pdf",
        "ppt",
        "pptx",
        "rtf",
        "txt",
        "vcf",
        "xls",
        "xlsx",
        "xml",
        "yaml",
        "yml",
        "zip",
    ]

    static var fileImporterAllowedTypes: [UTType] {
        var types: [UTType] = [.image, .movie, .audio, .pdf, .plainText, .rtf, .commaSeparatedText, .json]
        for ext in supportedDocumentExtensions.sorted() {
            if let type = UTType(filenameExtension: ext), !types.contains(type) {
                types.append(type)
            }
        }
        return types
    }

    static func canonicalMediaType(_ mediaType: String) -> String {
        let base = mediaType
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? mediaType
        let canonical = base.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return canonical == "image/jpg" ? "image/jpeg" : canonical
    }

    /// MIME types that classify as a renderable raster image. `image/*` covers
    /// the common cases, but `image/svg+xml` is deliberately excluded: SVG is an
    /// XML/script container, not a raster bitmap, and routing it to the image
    /// decode path expands the attack surface for peer-controlled bytes (see
    /// whitenoise-ios#242 / #233). SVG is treated as unsupported so it never
    /// reaches the ImageIO thumbnail decoder.
    static func isDecodableImageMediaType(_ mediaType: String) -> Bool {
        let canonical = canonicalMediaType(mediaType)
        guard canonical.hasPrefix("image/") else { return false }
        return canonical != "image/svg+xml"
    }

    static func isSupported(mediaType: String, fileName: String? = nil) -> Bool {
        let canonical = canonicalMediaType(mediaType)
        if isDecodableImageMediaType(canonical) { return true }
        if supportedVideoMediaTypes.contains(canonical) { return true }
        if supportedAudioMediaTypes.contains(canonical) { return true }
        if supportedDocumentMediaTypes.contains(canonical) { return true }
        if let fileExtension = safeFileExtension(from: fileName) {
            return supportedDocumentExtensions.contains(fileExtension)
        }
        return false
    }

    static func mediaType(typeIdentifier: String?, fileName: String?, fallbackKind: MediaAttachmentKind?) -> String? {
        if let typeIdentifier,
           let type = UTType(typeIdentifier),
           let mediaType = type.preferredMIMEType
        {
            return outgoingMediaType(canonicalMediaType(mediaType))
        }
        if let fileExtension = safeFileExtension(from: fileName),
           let mediaType = mediaType(forFileExtension: fileExtension)
        {
            return outgoingMediaType(canonicalMediaType(mediaType))
        }
        switch fallbackKind {
        case .video: return "video/mp4"
        case .audio: return "audio/mp4"
        case .image: return "image/jpeg"
        case .document, .unsupported, .none: return nil
        }
    }

    private static func outgoingMediaType(_ canonical: String) -> String {
        switch canonical {
        case "application/x-yaml", "text/yaml", "text/x-yaml": return "application/yaml"
        case "text/x-markdown": return "text/markdown"
        case "application/x-zip-compressed": return "application/zip"
        case "text/xml": return "application/xml"
        default: return canonical
        }
    }

    static func mediaType(forFileExtension fileExtension: String) -> String? {
        let lower = fileExtension.lowercased()
        guard isSafeFileExtension(lower) else { return nil }
        switch lower {
        case "m4a": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "mov": return "video/quicktime"
        case "mp4", "m4v": return "video/mp4"
        case "txt": return "text/plain"
        case "vcf": return "text/vcard"
        case "csv": return "text/csv"
        case "json": return "application/json"
        case "rtf": return "application/rtf"
        case "pdf": return "application/pdf"
        case "doc": return "application/msword"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls": return "application/vnd.ms-excel"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "ppt": return "application/vnd.ms-powerpoint"
        case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "md", "markdown": return "text/markdown"
        case "yaml", "yml": return "application/yaml"
        case "xml": return "application/xml"
        case "zip": return "application/zip"
        case "html", "htm": return "text/html"
        default:
            return UTType(filenameExtension: lower)?.preferredMIMEType
        }
    }

    static func fileExtension(for mediaType: String, fileName: String? = nil) -> String {
        if let ext = safeFileExtension(from: fileName) {
            return ext
        }
        switch canonicalMediaType(mediaType) {
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/heic": return "heic"
        case "image/webp": return "webp"
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        case "audio/aac", "audio/mp4", "audio/x-m4a": return "m4a"
        case "audio/mpeg": return "mp3"
        case "audio/wav", "audio/x-wav": return "wav"
        case "application/pdf": return "pdf"
        case "application/json", "text/json": return "json"
        case "application/rtf", "text/rtf": return "rtf"
        case "text/csv": return "csv"
        case "text/plain": return "txt"
        case "text/vcard": return "vcf"
        case "application/msword": return "doc"
        case "application/vnd.openxmlformats-officedocument.wordprocessingml.document": return "docx"
        case "application/vnd.ms-excel": return "xls"
        case "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": return "xlsx"
        case "application/vnd.ms-powerpoint": return "ppt"
        case "application/vnd.openxmlformats-officedocument.presentationml.presentation": return "pptx"
        case "text/markdown", "text/x-markdown": return "md"
        case "application/yaml", "application/x-yaml", "text/yaml", "text/x-yaml": return "yaml"
        case "application/xml", "text/xml": return "xml"
        case "application/zip", "application/x-zip-compressed": return "zip"
        case "text/html": return "html"
        default: return "bin"
        }
    }

    static func safeFileExtension(from fileName: String?) -> String? {
        guard let fileName else { return nil }
        let trimmedName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = (trimmedName as NSString).pathExtension.lowercased()
        return isSafeFileExtension(ext) ? ext : nil
    }

    private static func isSafeFileExtension(_ ext: String) -> Bool {
        let bytes = ext.utf8
        guard (1...12).contains(bytes.count) else { return false }
        return bytes.allSatisfy { byte in
            switch byte {
            case 0x30...0x39, 0x61...0x7A:
                return true
            default:
                return false
            }
        }
    }
}

nonisolated struct MessageMediaAttachment: Identifiable, Hashable {
    /// Waveform analysis and on-device transcription both need the whole encoded recording.
    static let audioAnalysisByteLimit = 16 * 1024 * 1024

    private(set) var id: String
    let displayIndex: UInt32?
    let reference: MediaAttachmentReferenceFfi?
    let fileName: String
    let mediaType: String
    let dim: String?
    private(set) var localData: Data?
    let thumbnail: UIImage?
    let durationSeconds: Double?
    let waveformSamples: [CGFloat]
    let rejectionKind: MediaAttachmentRejectionKindFfi?
    var localTarget: AttachmentLocalTargetFfi?
    var sourceHint: AttachmentSourceHint?
    var demand = AttachmentDemand.automatic
    var previewByteLimit: Int?

    init(
        id: String,
        reference: MediaAttachmentReferenceFfi?,
        fileName: String,
        mediaType: String,
        dim: String?,
        localData: Data?,
        thumbnail: UIImage? = nil,
        durationSeconds: Double? = nil,
        waveformSamples: [CGFloat] = [],
        rejectionKind: MediaAttachmentRejectionKindFfi? = nil,
        localTarget: AttachmentLocalTargetFfi? = nil,
        displayIndex: UInt32? = nil
    ) {
        self.displayIndex = displayIndex
        self.id = id
        self.reference = reference
        self.fileName = fileName
        self.mediaType = mediaType
        self.dim = dim
        self.localData = localData
        self.thumbnail = thumbnail
        self.durationSeconds = durationSeconds
        self.waveformSamples = waveformSamples
        self.rejectionKind = rejectionKind
        self.localTarget = localTarget
    }

    var isImage: Bool {
        MediaAttachmentPolicy.isDecodableImageMediaType(mediaType)
    }

    var isGIF: Bool {
        MediaAttachmentPolicy.canonicalMediaType(mediaType) == "image/gif"
    }

    /// GIFs play inline. Rejected slots retain their original unavailable row.
    var isTranscriptGalleryMedia: Bool {
        rejectionKind == nil && !isGIF && (isImage || isVideo)
    }

    var isVideo: Bool {
        MediaAttachmentPolicy.canonicalMediaType(mediaType).hasPrefix("video/")
    }

    var isAudio: Bool {
        MediaAttachmentPolicy.canonicalMediaType(mediaType).hasPrefix("audio/")
    }

    struct InlineRow: Identifiable {
        enum ID: Hashable {
            case attachment(String)
            case outgoingDocument(UInt32)
        }
        let id: ID
        let item: MessageMediaAttachment
    }

    func originalSlot(at position: Int) -> UInt32 {
        localTarget?.attachmentIndex ?? sourceHint?.slot ?? displayIndex ?? UInt32(position)
    }

    static func inlineRows(_ items: [Self], outgoing: Bool) -> [InlineRow] {
        items.enumerated().compactMap { index, item in
            guard !item.isTranscriptGalleryMedia else { return nil }
            let document = item.rejectionKind == nil && (item.kind == .document || item.kind == .unsupported)
            let slot = item.originalSlot(at: index)
            return InlineRow(id: outgoing && document ? .outgoingDocument(slot) : .attachment(item.id), item: item)
        }
    }

    /// Identifies the same sourced slot in a live row and the native history.
    /// A confirmed local send can keep its temporary row ID in the live window.
    func transcriptItem(in messageID: String) -> Self {
        guard !messageID.isEmpty, let reference, let index = localTarget?.attachmentIndex ?? sourceHint?.slot ?? displayIndex else { return self }
        var copy = self
        copy.id = Self.displayItemID(reference: reference, index: index, ownerId: TimelineItem.messageRowId(forMessageIdHex: messageID))
        return copy
    }

    /// A content-hash overlay can display a matching own send on another message.
    /// Opening a sourced transcript page must still go through that page's original slot.
    var forTranscriptPage: Self {
        var copy = self
        if AttachmentHandoffSource(self) != .none { copy.localData = nil }
        return copy
    }

    /// Delivery can supply the original source for an already displayed outgoing attachment.
    /// A replacement for a previously known slot must prepare its own bytes.
    func canUseBytesPrepared(for earlier: Self) -> Bool {
        preparedSource.canContinue(earlier.preparedSource)
    }

    struct PreparedSource: Equatable {
        let id: String
        let reference: MediaAttachmentReferenceFfi?
        let localTarget: AttachmentLocalTargetFfi?
        let sourceHint: AttachmentSourceHint?

        func canContinue(_ earlier: Self) -> Bool {
            guard id == earlier.id, reference == earlier.reference else { return false }
            if localTarget == earlier.localTarget { return localTarget != nil || sourceHint == earlier.sourceHint }
            return earlier.localTarget == nil && localTarget != nil && reference != nil
                && (earlier.sourceHint == nil || earlier.sourceHint == sourceHint)
        }
    }

    var preparedSource: PreparedSource {
        PreparedSource(id: id, reference: reference, localTarget: localTarget, sourceHint: sourceHint)
    }

    func isSameDocumentSource(as original: Self, leasedTarget: AttachmentLocalTargetFfi? = nil) -> Bool {
        guard id == original.id, reference == original.reference else { return false }
        if let leasedTarget {
            return AttachmentHandoffSource(self).matches(leasedTarget) && AttachmentHandoffSource(original).matches(leasedTarget)
        }
        return localTarget == original.localTarget && sourceHint == original.sourceHint && (reference != nil || localData == original.localData)
    }

    var isDocument: Bool {
        MediaAttachmentKind.classify(mediaType: mediaType, fileName: fileName) == .document
    }

    var kind: MediaAttachmentKind {
        MediaAttachmentKind.classify(mediaType: mediaType, fileName: fileName)
    }

    var rejectionMessage: String? {
        guard let rejectionKind else { return nil }
        return rejectionKind == .unsupportedFormat
            ? L10n.string("Unsupported attachment")
            : L10n.string("Attachment couldn’t be read")
    }

    static func displayItems(fromOutcomes outcomes: [MediaAttachmentOutcomeFfi], ownerId: String, messageId: String? = nil, sourceMessageId: String? = nil, resolveMissingSource: Bool = false) -> [MessageMediaAttachment] {
        outcomes.map { outcome in
            switch outcome {
            case .accepted(let index, let reference):
                var item = displayItem(reference: reference, index: index, ownerId: ownerId)
                if let messageId, !messageId.isEmpty, sourceMessageId != nil || resolveMissingSource {
                    item.sourceHint = AttachmentSourceHint(messageID: messageId, slot: index)
                }
                if let messageId, let sourceMessageId, !messageId.isEmpty, !sourceMessageId.isEmpty {
                    item.localTarget = AttachmentLocalTargetFfi(messageIdHex: messageId,
                        sourceMessageIdHex: sourceMessageId, attachmentIndex: index)
                }
                return item
            case .rejected(let index, let rejection):
                return MessageMediaAttachment(
                    id: "\(ownerId):rejected:\(index)", reference: nil,
                    fileName: L10n.string("Attachment"), mediaType: "", dim: nil, localData: nil,
                    rejectionKind: rejection.kind
                )
            }
        }
    }

    static func displayItems(
        from references: [MediaAttachmentReferenceFfi],
        ownerId: String
    ) -> [MessageMediaAttachment] {
        references.enumerated().map { index, reference in
            displayItem(reference: reference, index: UInt32(clamping: index), ownerId: ownerId)
        }
    }

    private static func displayItemID(reference: MediaAttachmentReferenceFfi, index: UInt32, ownerId: String) -> String {
        [ownerId, reference.plaintextSha256, String(reference.sourceEpoch), String(index)].joined(separator: ":")
    }

    private static func displayItem(reference: MediaAttachmentReferenceFfi, index: UInt32, ownerId: String) -> MessageMediaAttachment {
        MessageMediaAttachment(
            id: displayItemID(reference: reference, index: index, ownerId: ownerId),
            reference: reference,
            fileName: displayFileName(reference.fileName),
            mediaType: reference.mediaType,
            dim: reference.dim,
            localData: nil,
            thumbnail: nil,
            durationSeconds: nil,
            waveformSamples: [],
            displayIndex: index
        )
    }

    static func displayFileName(_ raw: String) -> String {
        ContentSanitizer.compactSingleLine(raw, maxLength: MessageSemantics.maxImetaFileNameBytes)
            ?? "Attachment"
    }

    static func == (lhs: MessageMediaAttachment, rhs: MessageMediaAttachment) -> Bool {
        lhs.id == rhs.id
            && lhs.reference == rhs.reference
            && lhs.fileName == rhs.fileName
            && lhs.mediaType == rhs.mediaType
            && lhs.dim == rhs.dim
            && lhs.localData == rhs.localData
            && lhs.durationSeconds == rhs.durationSeconds
            && lhs.waveformSamples == rhs.waveformSamples
            && lhs.rejectionKind == rhs.rejectionKind
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(reference)
        hasher.combine(fileName)
        hasher.combine(mediaType)
        hasher.combine(dim)
        hasher.combine(localData)
        hasher.combine(durationSeconds)
        hasher.combine(waveformSamples)
        hasher.combine(rejectionKind)
    }
}

nonisolated struct MediaDraftAttachment: Identifiable, Hashable {
    let id: UUID
    let fileName: String
    let mediaType: String
    let data: Data
    let dim: String?
    let thumbhash: String?
    let thumbnail: UIImage?
    let durationSeconds: Double?
    let waveformSamples: [CGFloat]

    var isGIF: Bool {
        MediaAttachmentPolicy.canonicalMediaType(mediaType) == "image/gif"
    }

    init(
        id: UUID = UUID(),
        fileName: String,
        mediaType: String,
        data: Data,
        dim: String?,
        thumbhash: String? = nil,
        thumbnail: UIImage? = nil,
        durationSeconds: Double? = nil,
        waveformSamples: [CGFloat] = []
    ) {
        self.id = id
        self.fileName = fileName
        self.mediaType = mediaType
        self.data = data
        self.dim = dim
        self.thumbhash = thumbhash
        self.thumbnail = thumbnail
        self.durationSeconds = durationSeconds
        self.waveformSamples = waveformSamples
    }

    var kind: MediaAttachmentKind {
        MediaAttachmentKind.classify(mediaType: mediaType, fileName: fileName)
    }

    var uploadRequest: MediaUploadAttachmentRequestFfi {
        MediaUploadAttachmentRequestFfi(
            fileName: fileName,
            mediaType: mediaType,
            plaintext: data,
            dim: dim,
            thumbhash: thumbhash
        )
    }

    var displayItem: MessageMediaAttachment {
        MessageMediaAttachment(
            id: id.uuidString,
            reference: nil,
            fileName: fileName,
            mediaType: mediaType,
            dim: dim,
            localData: data,
            thumbnail: thumbnail,
            durationSeconds: durationSeconds,
            waveformSamples: waveformSamples
        )
    }

    var messageDraftAttachment: MessageDraftAttachmentFfi {
        MessageDraftAttachmentFfi(
            id: id.uuidString,
            fileName: fileName,
            mediaType: mediaType,
            plaintext: data,
            dim: dim,
            thumbhash: thumbhash,
            durationSeconds: durationSeconds,
            waveformSamples: waveformSamples.map(Double.init)
        )
    }

    static func == (lhs: MediaDraftAttachment, rhs: MediaDraftAttachment) -> Bool {
        lhs.id == rhs.id
            && lhs.fileName == rhs.fileName
            && lhs.mediaType == rhs.mediaType
            && lhs.data == rhs.data
            && lhs.dim == rhs.dim
            && lhs.thumbhash == rhs.thumbhash
            && lhs.durationSeconds == rhs.durationSeconds
            && lhs.waveformSamples == rhs.waveformSamples
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(fileName)
        hasher.combine(mediaType)
        hasher.combine(data)
        hasher.combine(dim)
        hasher.combine(thumbhash)
        hasher.combine(durationSeconds)
        hasher.combine(waveformSamples)
    }
}

/// Reads a picked file without making it resident memory. The file is cloned
/// into a private directory, mapped, and unlinked at once, so the mapping is the
/// clone's only reference: its pages stay file-backed and reclaimable, and the
/// source (which a picker deletes or a file provider may change) is not mapped.
nonisolated enum PickedMediaFile {
    static let directoryName = "WhiteNoisePickedMedia"
    static let staleAge: TimeInterval = 60 * 60

    static var defaultDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }

    static func mappedData(from url: URL, in directory: URL = defaultDirectory, now: Date = Date()) throws -> Data {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        MediaUploadSourceFiles.removeStale(in: directory, olderThan: staleAge, now: now)
        let clone = directory.appendingPathComponent(UUID().uuidString, isDirectory: false)
        try manager.copyItem(at: url, to: clone)
        defer { try? manager.removeItem(at: clone) }
        guard MediaUploadSourceFiles.isRegularFile(at: clone) else { throw CocoaError(.fileReadUnknown) }
        // Not complete protection: once the device locks, a page fault in a
        // complete-protection mapping can't be decrypted and crashes the app.
        // The clone is unlinked before this returns, so nothing can reopen it.
        try manager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: clone.path
        )
        return try Data(contentsOf: clone, options: .alwaysMapped)
    }

    /// Writes the chunks `read` returns (from `offset`, until an empty chunk)
    /// into a private file and maps it, as `mappedData(from:)` maps a clone.
    /// `read` returning nil means the bytes are gone. Refuses a body whose
    /// size isn't `expectedSize`.
    static func mappedData(
        expectedSize: UInt64,
        in directory: URL = defaultDirectory,
        now: Date = Date(),
        read: (UInt64) async throws -> Data?
    ) async throws -> Data {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        MediaUploadSourceFiles.removeStale(in: directory, olderThan: staleAge, now: now)
        let copy = directory.appendingPathComponent(UUID().uuidString, isDirectory: false)
        // Not complete protection, for the same reason as a picked clone.
        guard manager.createFile(atPath: copy.path, contents: nil,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        else { throw CocoaError(.fileWriteUnknown) }
        defer { try? manager.removeItem(at: copy) }
        let handle = try FileHandle(forWritingTo: copy)
        var offset: UInt64 = 0
        do {
            while true {
                try Task.checkCancellation()
                guard let chunk = try await read(offset) else { throw CocoaError(.fileReadNoSuchFile) }
                if chunk.isEmpty { break }
                try handle.write(contentsOf: chunk)
                offset += UInt64(chunk.count)
                guard offset <= expectedSize else { throw CocoaError(.fileReadCorruptFile) }
            }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        guard offset == expectedSize else { throw CocoaError(.fileReadCorruptFile) }
        return try Data(contentsOf: copy, options: .alwaysMapped)
    }
}

/// How a composer attachment is saved into, or staged as a file in, MDK's draft.
nonisolated enum MessageDraftAttachmentInputs {
    /// MDK's chunk size for reading a file-backed draft attachment.
    static let readChunkBytes: UInt32 = 1024 * 1024

    /// Each attachment MDK already holds as a file is kept by id. Others go
    /// inline while drafts can hold their bytes; a large one MDK doesn't hold
    /// yet is left out, so the save never carries its bytes. MDK keeps every
    /// attachment a save doesn't name, after the named ones, so each one in
    /// `removing` (the draft's) that `attachments` don't name is removed.
    static func inputs(
        for attachments: [MediaDraftAttachment],
        retainedIDs: Set<String>,
        removingUnnamed removing: [String] = []
    ) -> [MessageDraftAttachmentInputFfi] {
        let named = Set(attachments.map(\.id.uuidString))
        return attachments.compactMap { attachment in
            let id = attachment.id.uuidString
            if retainedIDs.contains(id) { return .retained(id: id) }
            guard MediaDraftProcessor.persistsInDraft(attachment) else { return nil }
            return .inline(attachment: attachment.messageDraftAttachment)
        } + removing.filter { !named.contains($0) }.map { .removed(id: $0) }
    }

    /// A large attachment drafts can hold only as a file, which MDK copies in.
    static func needsStaging(_ attachment: MediaDraftAttachment) -> Bool {
        !MediaDraftProcessor.persistsInDraft(attachment)
            && attachment.data.count <= MediaDraftProcessor.maxAttachmentBytes
    }

    static func fileRequest(for attachment: MediaDraftAttachment, sourcePath: String) -> MessageDraftAttachmentFileRequestFfi {
        MessageDraftAttachmentFileRequestFfi(
            id: attachment.id.uuidString,
            sourcePath: sourcePath,
            expectedSize: UInt64(attachment.data.count),
            fileName: attachment.fileName,
            mediaType: attachment.mediaType,
            dim: attachment.dim,
            thumbhash: attachment.thumbhash,
            durationSeconds: attachment.durationSeconds,
            waveformSamples: attachment.waveformSamples.map(Double.init)
        )
    }

    /// The ids of attachments MDK holds as files in `selection`.
    static func fileBackedIDs(in selection: SelectedMessageDraftFfi?) -> Set<String> {
        Set(selection?.draft?.mediaAttachments.filter(\.fileBacked).map(\.id) ?? [])
    }
}

nonisolated enum MediaDraftProcessor {
    static let maxAttachmentCount = 10
    static let maxLongEdge: CGFloat = 2048
    static let maxImageAttachmentBytes = 10 * 1024 * 1024
    /// Images are decoded into a resident bitmap before they are re-encoded,
    /// so their source stays under this bound whatever the attachment cap.
    static let maxImageSourceBytes = 50 * 1024 * 1024
    /// MDK's largest encrypted media blob (512 MiB) less the AEAD tag that
    /// encryption adds to it.
    static let maxAttachmentBytes = 512 * 1024 * 1024 - Int(MediaFileUploadLimit.aeadTagBytes)
    /// MDK copies an inline draft attachment's bytes on each save, so larger
    /// attachments go into the draft as files instead
    /// (`MessageDraftAttachmentInputs`, `stageMessageDraftAttachmentFile`).
    static let maxDraftAttachmentBytes = 50 * 1024 * 1024
    static let draftThumbnailPixelSize: CGFloat = 160

    /// Whether a picked file of `kind` is sent as its own bytes. Images are
    /// decoded and re-encoded, so their source size is neither the upload size
    /// nor bound by the attachment cap.
    static func sendsSourceBytes(_ kind: MediaAttachmentKind) -> Bool {
        kind != .image
    }

    /// The size a picked file may have before it is copied: images are refused
    /// at their decode limit, everything else at the attachment cap.
    static func maxSourceBytes(for kind: MediaAttachmentKind) -> Int {
        sendsSourceBytes(kind) ? maxAttachmentBytes : maxImageSourceBytes
    }

    /// The composer's attachments once one more is added: new audio replaces
    /// the previous audio attachment.
    static func draftsKept(_ drafts: [MediaDraftAttachment], addingAudio: Bool) -> [MediaDraftAttachment] {
        addingAudio ? drafts.filter { $0.kind != .audio } : drafts
    }

    /// Whether drafts can hold the attachment's bytes inline.
    static func persistsInDraft(_ attachment: MediaDraftAttachment) -> Bool {
        attachment.data.count <= maxDraftAttachmentBytes
    }

    /// A message carrying an attachment the draft doesn't hold, inline or as a
    /// file MDK has staged (`fileBackedIDs`), is sent without a draft revision,
    /// and nothing in it is uploaded ahead of Send.
    static func sendsThroughDraft(_ attachments: [MediaDraftAttachment], fileBackedIDs: Set<String> = []) -> Bool {
        attachments.allSatisfy { persistsInDraft($0) || fileBackedIDs.contains($0.id.uuidString) }
    }

    @MainActor
    /// Off the MainActor, as the picker prepares: a video's thumbnail writes
    /// its bytes to a temporary file, and a file-backed one can be 512 MiB.
    static func restoredDraftAttachments(
        from stored: [MessageDraftAttachmentFfi]
    ) async -> [MediaDraftAttachment] {
        await Task.detached(priority: .userInitiated) {
            await restoredDraftAttachmentsValue(from: stored)
        }.value
    }

    private static func restoredDraftAttachmentsValue(
        from stored: [MessageDraftAttachmentFfi]
    ) async -> [MediaDraftAttachment] {
        var restored: [MediaDraftAttachment] = []
        var ids = Set<UUID>()
        for attachment in stored.prefix(maxAttachmentCount) {
            let id = UUID(uuidString: attachment.id) ?? UUID()
            guard ids.insert(id).inserted else { continue }
            let kind = MediaAttachmentKind.classify(
                mediaType: attachment.mediaType,
                fileName: attachment.fileName
            )
            let maxBytes = kind == .image ? maxImageAttachmentBytes : maxAttachmentBytes
            guard attachment.plaintext.count <= maxBytes,
                  attachment.durationSeconds?.isFinite != false,
                  attachment.waveformSamples.allSatisfy(\.isFinite)
            else { continue }

            let thumbnail: UIImage?
            let restoredDim: String?
            switch kind {
            case .image:
                thumbnail = await MessageMediaThumbnailDecoder.image(
                    data: attachment.plaintext,
                    maxPixelSize: Int(draftThumbnailPixelSize),
                    scale: 1
                )
                restoredDim = attachment.dim
            case .video:
                let videoMetadata = await MediaVideoMetadata.metadata(
                    from: attachment.plaintext,
                    mediaType: attachment.mediaType
                )
                thumbnail = videoMetadata.thumbnail
                restoredDim = videoMetadata.dim ?? attachment.dim
            case .audio, .document, .unsupported:
                thumbnail = nil
                restoredDim = attachment.dim
            }

            restored.append(MediaDraftAttachment(
                id: id,
                fileName: attachment.fileName,
                mediaType: attachment.mediaType,
                data: attachment.plaintext,
                dim: restoredDim,
                thumbhash: attachment.thumbhash,
                thumbnail: thumbnail,
                durationSeconds: attachment.durationSeconds,
                waveformSamples: attachment.waveformSamples.map { CGFloat($0) }
            ))
        }
        return restored
    }

    enum Failure: LocalizedError {
        case unsupportedImage
        case unsupportedAttachment
        case encodingFailed
        case attachmentTooLarge(Int)

        var errorDescription: String? {
            switch self {
            case .unsupportedImage:
                return L10n.string("That image could not be opened.")
            case .unsupportedAttachment:
                return L10n.string("That file type is not supported.")
            case .encodingFailed:
                return L10n.string("That attachment could not be prepared.")
            case .attachmentTooLarge:
                return L10n.string("That attachment is too large to send.")
            }
        }
    }

    static func preparedAttachment(from data: Data, fileName: String?) async throws -> MediaDraftAttachment {
        try await preparedAttachment(from: data, fileName: fileName, typeIdentifier: nil)
    }

    static func preparedAttachment(
        from data: Data,
        fileName: String?,
        typeIdentifier: String?
    ) async throws -> MediaDraftAttachment {
        try await Task.detached(priority: .userInitiated) { () async throws -> MediaDraftAttachment in
            try await preparedAttachmentValue(
                from: data,
                fileName: fileName,
                typeIdentifier: typeIdentifier
            )
        }.value
    }

    static func preparedAttachment(fromFileURL url: URL) async throws -> MediaDraftAttachment {
        try await Task.detached(priority: .userInitiated) { () async throws -> MediaDraftAttachment in
            let resourceValues = try url.resourceValues(forKeys: [.contentTypeKey, .nameKey, .fileSizeKey])
            let fileName = resourceValues.name ?? url.lastPathComponent
            let typeIdentifier = resourceValues.contentType?.identifier
            let kind = kind(for: typeIdentifier, fileName: fileName)
            if let size = resourceValues.fileSize, size > maxSourceBytes(for: kind) {
                throw Failure.attachmentTooLarge(size)
            }
            if kind == .video {
                guard let mediaType = MediaAttachmentPolicy.mediaType(
                    typeIdentifier: typeIdentifier,
                    fileName: fileName,
                    fallbackKind: kind
                ), MediaAttachmentPolicy.isSupported(mediaType: mediaType, fileName: fileName) else {
                    throw Failure.unsupportedAttachment
                }
                let stripped = try await MediaVideoMetadataStripper.strip(
                    sourceURL: url,
                    preferredMediaType: mediaType
                )
                return try genericAttachment(
                    from: stripped.data,
                    fileName: adjustedVideoFileName(fileName, originalMediaType: mediaType, strippedMediaType: stripped.mediaType),
                    mediaType: stripped.mediaType,
                    kind: .video,
                    videoMetadata: MediaVideoMetadata.Metadata(dim: stripped.dim, thumbnail: stripped.thumbnail)
                )
            }
            let data = try PickedMediaFile.mappedData(from: url)
            return try await preparedAttachmentValue(
                from: data,
                fileName: fileName,
                typeIdentifier: typeIdentifier
            )
        }.value
    }

    static func preparedVoiceAttachment(from recording: VoiceRecordingResult) async throws -> MediaDraftAttachment {
        try await Task.detached(priority: .userInitiated) { () throws -> MediaDraftAttachment in
            defer { try? FileManager.default.removeItem(at: recording.url) }
            let data = try Data(contentsOf: recording.url)
            guard data.count <= maxAttachmentBytes else {
                throw Failure.attachmentTooLarge(data.count)
            }
            let fileName = sanitizedFileName(
                recording.fileName,
                fallbackStem: "voice-\(Int(Date().timeIntervalSince1970))",
                fallbackExtension: "m4a"
            )
            return MediaDraftAttachment(
                fileName: fileName,
                mediaType: "audio/mp4",
                data: data,
                dim: nil,
                durationSeconds: recording.durationSeconds,
                waveformSamples: MediaWaveformAnalyzer.normalized(recording.waveformSamples)
            )
        }.value
    }

    static func preparedAttachment(from image: sending UIImage, fileName: String?) async throws -> MediaDraftAttachment {
        try await Task.detached(priority: .userInitiated) { () throws -> MediaDraftAttachment in
            try attachment(from: image, fileName: fileName)
        }.value
    }

    static func attachment(from data: Data, fileName: String?) throws -> MediaDraftAttachment {
        try attachment(from: data, fileName: fileName, typeIdentifier: nil)
    }

    static func attachment(from data: Data, fileName: String?, typeIdentifier: String?) throws -> MediaDraftAttachment {
        try attachment(from: data, fileName: fileName, typeIdentifier: typeIdentifier, videoMetadata: nil)
    }

    private static func preparedAttachmentValue(
        from data: Data,
        fileName: String?,
        typeIdentifier: String?
    ) async throws -> MediaDraftAttachment {
        let kind = kind(for: typeIdentifier, fileName: fileName)
        if kind == .video {
            guard let mediaType = MediaAttachmentPolicy.mediaType(
                typeIdentifier: typeIdentifier,
                fileName: fileName,
                fallbackKind: kind
            ), MediaAttachmentPolicy.isSupported(mediaType: mediaType, fileName: fileName) else {
                throw Failure.unsupportedAttachment
            }
            guard data.count <= maxAttachmentBytes else {
                throw Failure.attachmentTooLarge(data.count)
            }
            let stripped = try await MediaVideoMetadataStripper.strip(
                data: data,
                preferredMediaType: mediaType
            )
            return try genericAttachment(
                from: stripped.data,
                fileName: adjustedVideoFileName(fileName, originalMediaType: mediaType, strippedMediaType: stripped.mediaType),
                mediaType: stripped.mediaType,
                kind: .video,
                videoMetadata: MediaVideoMetadata.Metadata(dim: stripped.dim, thumbnail: stripped.thumbnail)
            )
        }
        return try attachment(
            from: data,
            fileName: fileName,
            typeIdentifier: typeIdentifier,
            videoMetadata: nil
        )
    }

    private static func adjustedVideoFileName(
        _ fileName: String?,
        originalMediaType: String,
        strippedMediaType: String
    ) -> String? {
        guard originalMediaType != strippedMediaType, let fileName else { return fileName }
        let targetExtension = MediaAttachmentPolicy.fileExtension(for: strippedMediaType)
        let stem = (fileName as NSString).deletingPathExtension
        guard !stem.isEmpty else { return fileName }
        return "\(stem).\(targetExtension)"
    }

    private static func attachment(
        from data: Data,
        fileName: String?,
        typeIdentifier: String?,
        videoMetadata: MediaVideoMetadata.Metadata?
    ) throws -> MediaDraftAttachment {
        let decodable = data.count <= maxImageSourceBytes
        if decodable, let gif = animatedGIFAttachment(from: data, fileName: fileName) {
            return gif
        }
        if let typeIdentifier,
           let type = UTType(typeIdentifier),
           type.conforms(to: .image)
        {
            guard decodable else { throw Failure.attachmentTooLarge(data.count) }
            guard let image = UIImage(data: data) else {
                throw Failure.unsupportedImage
            }
            return try attachment(from: image, fileName: fileName)
        }

        if typeIdentifier == nil, decodable, let image = UIImage(data: data) {
            return try attachment(from: image, fileName: fileName)
        }

        let kind = kind(for: typeIdentifier, fileName: fileName)
        if kind == .image {
            guard decodable else { throw Failure.attachmentTooLarge(data.count) }
            guard let image = UIImage(data: data) else {
                throw Failure.unsupportedImage
            }
            return try attachment(from: image, fileName: fileName)
        }
        guard kind == .video || kind == .audio || kind == .document,
              let mediaType = MediaAttachmentPolicy.mediaType(
                typeIdentifier: typeIdentifier,
                fileName: fileName,
                fallbackKind: kind
              ),
              MediaAttachmentPolicy.isSupported(mediaType: mediaType, fileName: fileName)
        else {
            throw Failure.unsupportedAttachment
        }
        guard data.count <= maxAttachmentBytes else {
            throw Failure.attachmentTooLarge(data.count)
        }
        return try genericAttachment(
            from: data,
            fileName: fileName,
            mediaType: mediaType,
            kind: kind,
            videoMetadata: videoMetadata
        )
    }

    static func kind(for typeIdentifier: String?, fileName: String?) -> MediaAttachmentKind {
        if let typeIdentifier, let type = UTType(typeIdentifier) {
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .movie) { return .video }
            if type.conforms(to: .audio) { return .audio }
            if type.conforms(to: .pdf)
                || type.conforms(to: .text)
                || type.conforms(to: .data)
            {
                return MediaAttachmentKind.classify(
                    mediaType: MediaAttachmentPolicy.mediaType(
                        typeIdentifier: typeIdentifier,
                        fileName: fileName,
                        fallbackKind: nil
                    ) ?? "",
                    fileName: fileName
                )
            }
        }
        if let fileExtension = MediaAttachmentPolicy.safeFileExtension(from: fileName),
           let mediaType = MediaAttachmentPolicy.mediaType(forFileExtension: fileExtension)
        {
            return MediaAttachmentKind.classify(mediaType: mediaType, fileName: fileName)
        }
        return .unsupported
    }

    private static func genericAttachment(
        from data: Data,
        fileName: String?,
        mediaType: String,
        kind: MediaAttachmentKind,
        videoMetadata: MediaVideoMetadata.Metadata? = nil
    ) throws -> MediaDraftAttachment {
        let sanitizedName = sanitizedFileName(
            fileName,
            fallbackStem: kind == .audio ? "audio-\(Int(Date().timeIntervalSince1970))" : "attachment-\(Int(Date().timeIntervalSince1970))",
            fallbackExtension: MediaAttachmentPolicy.fileExtension(for: mediaType, fileName: fileName)
        )
        let audioMetadata = kind == .audio ? MediaWaveformAnalyzer.metadata(from: data, mediaType: mediaType) : nil
        return MediaDraftAttachment(
            fileName: sanitizedName,
            mediaType: mediaType,
            data: data,
            dim: videoMetadata?.dim,
            thumbnail: videoMetadata?.thumbnail,
            durationSeconds: audioMetadata?.durationSeconds,
            waveformSamples: audioMetadata?.samples ?? []
        )
    }

    static func imageAttachment(from data: Data, fileName: String?) throws -> MediaDraftAttachment {
        if let gif = animatedGIFAttachment(from: data, fileName: fileName) {
            return gif
        }
        guard let image = UIImage(data: data) else {
            throw Failure.unsupportedImage
        }
        return try attachment(from: image, fileName: fileName)
    }

    private static func animatedGIFAttachment(from data: Data, fileName: String?) -> MediaDraftAttachment? {
        guard let source = try? AttachmentGIF.source(from: data) else { return nil }
        return try? gifAttachment(from: source, fileName: fileName)
    }

    private static func gifAttachment(from source: CGImageSource, fileName: String?) throws -> MediaDraftAttachment {
        let count = CGImageSourceGetCount(source)
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.gif.identifier as CFString, count, nil) else {
            throw Failure.encodingFailed
        }
        let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        if let loopCount = gif?[kCGImagePropertyGIFLoopCount] {
            CGImageDestinationSetProperties(destination, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loopCount],
            ] as CFDictionary)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: min(MediaQualityStore.quality().imageMaxEdgePx, AttachmentGIF.maxPixelEdge),
            kCGImageSourceShouldCache: false,
        ]
        var thumbnail: UIImage?
        var dim: String?
        for index in 0..<count {
            try autoreleasepool {
                guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
                    throw Failure.unsupportedImage
                }
                let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
                let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any] ?? [:]
                // Rebuild pixels and carry only animation timing; never copy source metadata.
                let timing = gif.filter { $0.key == kCGImagePropertyGIFDelayTime || $0.key == kCGImagePropertyGIFUnclampedDelayTime }
                CGImageDestinationAddImage(destination, frame, [kCGImagePropertyGIFDictionary: timing] as CFDictionary)
                if index == 0 {
                    dim = "\(frame.width)x\(frame.height)"
                    thumbnail = thumbnailImage(from: UIImage(cgImage: frame))
                }
            }
        }
        guard CGImageDestinationFinalize(destination) else { throw Failure.encodingFailed }
        guard encoded.length <= maxImageAttachmentBytes else { throw Failure.attachmentTooLarge(encoded.length) }
        var name = sanitizedFileName(fileName, fallbackStem: "animation", fallbackExtension: "gif")
        if !name.lowercased().hasSuffix(".gif") {
            name = "\((name as NSString).deletingPathExtension).gif"
        }
        return MediaDraftAttachment(
            fileName: name, mediaType: "image/gif", data: encoded as Data, dim: dim,
            thumbhash: thumbnail.flatMap { ThumbHash.encodedString(from: $0) }, thumbnail: thumbnail
        )
    }

    static func attachment(
        from image: UIImage,
        fileName: String?,
        quality: MediaQuality = MediaQualityStore.quality()
    ) throws -> MediaDraftAttachment {
        let normalized = normalizedImage(image, maxLongEdge: quality.imageMaxEdgePx)
        let encoded = try encodeJPEG(normalized, qualityLadder: quality.imageJPEGQualityLadder)
        guard encoded.count <= maxImageAttachmentBytes else {
            throw Failure.attachmentTooLarge(encoded.count)
        }
        let width = max(1, Int(normalized.size.width.rounded()))
        let height = max(1, Int(normalized.size.height.rounded()))
        return MediaDraftAttachment(
            fileName: sanitizedImageFileName(fileName),
            mediaType: "image/jpeg",
            data: encoded,
            dim: "\(width)x\(height)",
            thumbhash: ThumbHash.encodedString(from: normalized),
            thumbnail: thumbnailImage(from: normalized)
        )
    }

    private static func normalizedImage(
        _ image: UIImage,
        maxLongEdge: CGFloat = MediaDraftProcessor.maxLongEdge
    ) -> UIImage {
        // Canvas must use the oriented size: cgImage dimensions are pre-EXIF-rotation
        // (camera portraits are landscape bitmaps tagged .right), while draw(in:)
        // renders rotation-applied content. Mixing the two squashes the photo.
        // The re-render is also the metadata privacy floor: EXIF/GPS/maker
        // notes never survive it, at any quality level.
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let longest = max(pixelWidth, pixelHeight)
        let scale = longest > maxLongEdge ? maxLongEdge / longest : 1
        let size = CGSize(
            width: max(1, (pixelWidth * scale).rounded()),
            height: max(1, (pixelHeight * scale).rounded())
        )

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemBackground.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private static func encodeJPEG(
        _ image: UIImage,
        qualityLadder: [CGFloat] = MediaQuality.standard.imageJPEGQualityLadder
    ) throws -> Data {
        var last: Data?
        for quality in qualityLadder {
            guard let data = image.jpegData(compressionQuality: quality) else { continue }
            last = data
            if data.count <= maxImageAttachmentBytes {
                return data
            }
        }
        guard let data = last else {
            throw Failure.encodingFailed
        }
        return data
    }

    private static func thumbnailImage(from image: UIImage) -> UIImage {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let longest = max(pixelWidth, pixelHeight)
        let scale = longest > draftThumbnailPixelSize ? draftThumbnailPixelSize / longest : 1
        let size = CGSize(
            width: max(1, (pixelWidth * scale).rounded()),
            height: max(1, (pixelHeight * scale).rounded())
        )

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private static func sanitizedImageFileName(_ fileName: String?) -> String {
        let name = sanitizedFileName(
            fileName,
            fallbackStem: "photo-\(Int(Date().timeIntervalSince1970))",
            fallbackExtension: "jpg"
        )
        let lower = name.lowercased()
        if lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") {
            return name
        }
        return "\(name).jpg"
    }

    private static func sanitizedFileName(
        _ fileName: String?,
        fallbackStem: String,
        fallbackExtension: String
    ) -> String {
        let base = fileName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/")
            .last
            .map(String.init)
        let stem = base?
            .replacingOccurrences(of: #"[^A-Za-z0-9._-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        guard let stem, !stem.isEmpty else {
            return "\(fallbackStem).\(fallbackExtension)"
        }
        let capped = String(stem.prefix(120))
        if capped.contains(".") {
            return capped
        }
        return "\(capped).\(fallbackExtension)"
    }
}

nonisolated enum MediaWaveformAnalyzer {
    struct Metadata: Sendable {
        let durationSeconds: Double?
        let samples: [CGFloat]
    }

    static let sampleCount = 36

    static func normalized(_ values: [CGFloat], count: Int = sampleCount) -> [CGFloat] {
        let bounded = values.map { min(1, max(0.05, $0)) }
        guard !bounded.isEmpty else { return fallback(count: count) }
        if bounded.count == count { return bounded }
        let bucketSize = Double(bounded.count) / Double(count)
        return (0..<count).map { index in
            let start = Int((Double(index) * bucketSize).rounded(.down))
            let end = min(bounded.count, Int((Double(index + 1) * bucketSize).rounded(.up)))
            let slice = bounded[max(0, start)..<max(start + 1, end)]
            return max(0.08, slice.reduce(0, +) / CGFloat(slice.count))
        }
    }

    static func fallback(count: Int = sampleCount) -> [CGFloat] {
        (0..<count).map { index in
            let phase = CGFloat(index % 9) / 8
            return 0.24 + sin(phase * .pi) * 0.48
        }
    }

    /// Upper bound on frames decoded per streaming read. The analyzer reuses one
    /// buffer instead of sizing a buffer to the whole file, which keeps peak PCM
    /// memory bounded regardless of the decoded file length. Received audio is
    /// peer-controlled and decodes far larger than its compressed size, so
    /// a whole-file buffer is remotely triggerable OOM (see whitenoise-ios#208).
    /// This is only a frame ceiling; the actual per-read capacity is also bounded
    /// in *bytes* by `maxChunkBytes` so a hostile channel count cannot inflate the
    /// allocation (a fixed frame count alone would still allocate
    /// `frames * channelCount * bytesPerSample`).
    static let chunkFrameCapacityCeiling: AVAudioFrameCount = 65_536

    /// Hard ceiling on the bytes a single streaming read buffer may allocate,
    /// independent of the peer-controlled channel count. The per-frame PCM cost
    /// scales with channel count, so a fixed frame count does not bound memory;
    /// the chunk frame capacity is derived from this budget instead. 4 MiB.
    static let maxChunkBytes: Int = 4 * 1024 * 1024

    /// Reject audio whose declared channel count is implausible. Real-world audio
    /// messages are mono/stereo; a handful of channels covers legitimate
    /// multichannel content, while a peer-supplied container can declare
    /// thousands purely to force a large allocation. Defense in depth on top of
    /// the byte budget so the streaming loop never degenerates into tiny reads.
    static let maxChannelCount: AVAudioChannelCount = 32

    /// Frames to allocate per streaming read, derived from a fixed PCM byte
    /// budget so the buffer allocation (`frames * channelCount * bytesPerSample`)
    /// stays bounded regardless of the peer-controlled channel count. Clamped to
    /// at least one frame and at most `chunkFrameCapacityCeiling`. Pure helper for
    /// testability — this is the byte-budget invariant the OOM fix depends on.
    static func chunkFrameCapacity(
        channelCount: AVAudioChannelCount,
        bytesPerSample: Int
    ) -> AVAudioFrameCount {
        let channels = max(1, Int(channelCount))
        let sampleBytes = max(1, bytesPerSample)
        let perFrameBytes = channels * sampleBytes
        let framesInBudget = max(1, maxChunkBytes / perFrameBytes)
        let clamped = min(framesInBudget, Int(chunkFrameCapacityCeiling))
        return AVAudioFrameCount(clamped)
    }

    /// Hard ceiling on frames analyzed for the waveform, independent of the
    /// file's declared length. ~30 minutes at 48 kHz. Defends against a hostile
    /// declared length forcing unbounded decode work; the waveform only needs a
    /// coarse 36-bucket shape, so truncating very long audio is acceptable.
    static let maxAnalyzedFrames: AVAudioFramePosition = 48_000 * 60 * 30

    /// Clamp the number of frames analyzed so a peer-controlled declared length
    /// cannot force unbounded work. Pure helper for testability.
    static func analyzedFrameCount(totalFrames: AVAudioFramePosition) -> AVAudioFramePosition {
        guard totalFrames > 0 else { return 0 }
        return min(totalFrames, maxAnalyzedFrames)
    }

    /// Frames to request on the next read, never exceeding the per-read chunk
    /// capacity. This is the invariant that keeps memory bounded: even for a
    /// multi-gigabyte declared length, no single read allocates more than
    /// `chunkCapacity` frames. Pure helper for testability.
    static func nextChunkFrameCount(
        analyzedFrames: AVAudioFramePosition,
        framesProcessed: AVAudioFramePosition,
        chunkCapacity: AVAudioFrameCount
    ) -> AVAudioFrameCount {
        let remaining = analyzedFrames - framesProcessed
        guard remaining > 0 else { return 0 }
        return AVAudioFrameCount(min(AVAudioFramePosition(chunkCapacity), remaining))
    }

    /// Map an absolute frame index onto its waveform bucket, clamped into range.
    /// Pure helper for testability.
    static func bucketIndex(
        forFrame frame: AVAudioFramePosition,
        analyzedFrames: AVAudioFramePosition,
        bucketCount: Int = sampleCount
    ) -> Int {
        guard analyzedFrames > 0, bucketCount > 0 else { return 0 }
        let index = Int(frame * AVAudioFramePosition(bucketCount) / analyzedFrames)
        return min(bucketCount - 1, max(0, index))
    }

    static func metadata(from data: Data, mediaType: String) -> Metadata {
        TemporaryMediaFile.withURL(data: data, fileExtension: MediaAttachmentPolicy.fileExtension(for: mediaType)) { url in
            do {
                let file = try AVAudioFile(forReading: url)
                let format = file.processingFormat
                let sampleRate = format.sampleRate
                let totalFrames = file.length
                let duration = sampleRate > 0 ? Double(totalFrames) / sampleRate : nil

                let analyzedFrames = analyzedFrameCount(totalFrames: totalFrames)
                guard analyzedFrames > 0 else {
                    return Metadata(durationSeconds: duration, samples: fallback())
                }

                // Reject implausible channel counts: a peer-supplied container can
                // declare thousands of channels purely to inflate the PCM buffer.
                let channelCount = format.channelCount
                guard channelCount > 0, channelCount <= maxChannelCount else {
                    return Metadata(durationSeconds: duration, samples: fallback())
                }

                // Derive the per-read frame capacity from a fixed PCM *byte*
                // budget so the buffer allocation stays bounded regardless of the
                // (peer-controlled) channel count. A fixed frame count alone would
                // still allocate `frames * channelCount * bytesPerSample` bytes.
                // `mBitsPerChannel` is the per-sample width (32 for the float
                // processing format); fall back to Float size if it is unset.
                let bitsPerChannel = Int(format.streamDescription.pointee.mBitsPerChannel)
                let bytesPerSample = bitsPerChannel > 0
                    ? (bitsPerChannel + 7) / 8
                    : MemoryLayout<Float>.size
                let chunkCapacity = chunkFrameCapacity(
                    channelCount: channelCount,
                    bytesPerSample: bytesPerSample
                )

                // One reusable, byte-budget-bounded buffer — never sized to the file.
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: chunkCapacity
                ) else {
                    return Metadata(durationSeconds: duration, samples: fallback())
                }

                var peaks = [Float](repeating: 0, count: sampleCount)
                var counts = [Int](repeating: 0, count: sampleCount)
                var framesProcessed: AVAudioFramePosition = 0

                do {
                    while true {
                        let toRead = nextChunkFrameCount(
                            analyzedFrames: analyzedFrames,
                            framesProcessed: framesProcessed,
                            chunkCapacity: chunkCapacity
                        )
                        guard toRead > 0 else { break }
                        buffer.frameLength = 0
                        try file.read(into: buffer, frameCount: toRead)
                        let read = Int(buffer.frameLength)
                        guard read > 0, let channel = buffer.floatChannelData?[0] else { break }
                        for offset in 0..<read {
                            let bucket = bucketIndex(
                                forFrame: framesProcessed + AVAudioFramePosition(offset),
                                analyzedFrames: analyzedFrames
                            )
                            let value = abs(channel[offset])
                            if value > peaks[bucket] { peaks[bucket] = value }
                            counts[bucket] += 1
                        }
                        framesProcessed += AVAudioFramePosition(read)
                    }
                } catch {
                    return Metadata(durationSeconds: duration, samples: fallback())
                }

                guard framesProcessed > 0 else {
                    return Metadata(durationSeconds: duration, samples: fallback())
                }

                let samples = (0..<sampleCount).map { index -> CGFloat in
                    guard counts[index] > 0 else { return 0.08 }
                    return CGFloat(min(1, max(0.05, sqrt(peaks[index]))))
                }
                return Metadata(durationSeconds: duration, samples: normalized(samples))
            } catch {
                return Metadata(durationSeconds: nil, samples: fallback())
            }
        }
    }
}

nonisolated enum MediaVideoDimensionPolicy {
    static let maximumPixelDimension: CGFloat = 32_768

    static func integerDimension(_ value: CGFloat) -> Int? {
        guard value.isFinite else { return nil }
        let rounded = abs(value).rounded()
        guard rounded >= 1, rounded <= maximumPixelDimension else { return nil }
        return Int(rounded)
    }
}

nonisolated private enum MediaVideoMetadata {
    struct Metadata: Sendable {
        let dim: String?
        let thumbnail: UIImage?
    }

    static func metadata(from data: Data, mediaType: String) async -> Metadata {
        await TemporaryMediaFile.withURL(data: data, fileExtension: MediaAttachmentPolicy.fileExtension(for: mediaType)) { url in
            await metadata(for: AVURLAsset(url: url))
        }
    }

    static func metadata(for asset: AVURLAsset) async -> Metadata {
        let dim = await dimensions(for: asset)
        let thumbnail = await thumbnail(for: asset)
        return Metadata(dim: dim, thumbnail: thumbnail)
    }

    private static func dimensions(for asset: AVURLAsset) async -> String? {
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                return nil
            }
            async let naturalSize = track.load(.naturalSize)
            async let preferredTransform = track.load(.preferredTransform)
            let (size, transform) = try await (naturalSize, preferredTransform)
            let transformed = size.applying(transform)
            guard let width = MediaVideoDimensionPolicy.integerDimension(transformed.width),
                  let height = MediaVideoDimensionPolicy.integerDimension(transformed.height)
            else { return nil }
            return "\(width)x\(height)"
        } catch {
            return nil
        }
    }

    private static func thumbnail(for asset: AVURLAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(
                width: MediaDraftProcessor.draftThumbnailPixelSize,
                height: MediaDraftProcessor.draftThumbnailPixelSize
            )
            generator.generateCGImageAsynchronously(for: .zero) { image, _, error in
                guard let image, error == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: UIImage(cgImage: image))
            }
        }
    }
}

/// Strips container, track, and timed metadata (GPS coordinates, make/model,
/// software, creation date) from outgoing videos via compressed passthrough
/// remuxing without re-encoding. Fails closed if stripping cannot complete.
nonisolated enum MediaVideoMetadataStripper {
    static let directoryName = "WhiteNoiseVideoStrip"
    static let staleAge: TimeInterval = 60 * 60

    static var defaultDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }

    struct StrippedVideo: Sendable {
        let data: Data
        let mediaType: String
        let dim: String?
        let thumbnail: UIImage?
    }

    private struct PreparedTrackPair {
        let output: AVAssetReaderTrackOutput
        let input: AVAssetWriterInput
        let firstSample: CMSampleBuffer?
    }

    static func strip(
        data: Data,
        preferredMediaType: String,
        directory: URL = defaultDirectory,
        now: Date = Date()
    ) async throws -> StrippedVideo {
        guard !data.isEmpty else { throw MediaDraftProcessor.Failure.encodingFailed }
        guard data.count <= MediaDraftProcessor.maxAttachmentBytes else {
            throw MediaDraftProcessor.Failure.attachmentTooLarge(data.count)
        }
        try prepareDirectory(directory, now: now)
        let inputURL = try writeProtectedTempFile(
            data: data,
            fileExtension: MediaAttachmentPolicy.fileExtension(for: preferredMediaType),
            in: directory
        )
        defer { try? FileManager.default.removeItem(at: inputURL) }
        return try await stripOwnedFile(
            at: inputURL,
            preferredMediaType: preferredMediaType,
            directory: directory
        )
    }

    static func strip(
        sourceURL: URL,
        preferredMediaType: String,
        directory: URL = defaultDirectory,
        now: Date = Date()
    ) async throws -> StrippedVideo {
        let manager = FileManager.default
        try prepareDirectory(directory, now: now)

        // Always snapshot the external file-provider URL into a private bounded
        // regular file first so the provider cannot mutate bytes or exceed the
        // attachment limit between validation and AVFoundation's track reads.
        let ext = sourceURL.pathExtension.lowercased()
        let copyExtension = (ext == "mov" || ext == "mp4" || ext == "m4v")
            ? ext
            : MediaAttachmentPolicy.fileExtension(for: preferredMediaType)
        let copyURL = directory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
            .appendingPathExtension(copyExtension)
        try copyRegularFileBounded(
            from: sourceURL,
            to: copyURL,
            maxBytes: MediaDraftProcessor.maxAttachmentBytes
        )
        defer { try? manager.removeItem(at: copyURL) }

        return try await stripOwnedFile(
            at: copyURL,
            preferredMediaType: preferredMediaType,
            directory: directory
        )
    }

    private static func copyRegularFileBounded(
        from sourceURL: URL,
        to destinationURL: URL,
        maxBytes: Int
    ) throws {
        let srcFD = sourceURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_NOFOLLOW)
        }
        guard srcFD >= 0 else {
            throw MediaDraftProcessor.Failure.encodingFailed
        }
        defer { Darwin.close(srcFD) }

        var st = stat()
        guard Darwin.fstat(srcFD, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG
        else {
            throw MediaDraftProcessor.Failure.encodingFailed
        }

        let dstFD = destinationURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        }
        guard dstFD >= 0 else {
            throw MediaDraftProcessor.Failure.encodingFailed
        }
        var succeeded = false
        defer {
            Darwin.close(dstFD)
            if !succeeded {
                try? FileManager.default.removeItem(at: destinationURL)
            }
        }
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: destinationURL.path
        )

        let chunkSize = 256 * 1024
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var totalWritten = 0
        while true {
            try Task.checkCancellation()
            let readCount = buffer.withUnsafeMutableBytes { raw -> Int in
                Darwin.read(srcFD, raw.baseAddress, chunkSize)
            }
            if readCount < 0 {
                if errno == EINTR { continue }
                throw MediaDraftProcessor.Failure.encodingFailed
            }
            if readCount == 0 { break }
            if totalWritten + readCount > maxBytes {
                throw MediaDraftProcessor.Failure.attachmentTooLarge(totalWritten + readCount)
            }
            var offset = 0
            while offset < readCount {
                let written = buffer.withUnsafeBytes { raw -> Int in
                    Darwin.write(dstFD, raw.baseAddress!.advanced(by: offset), readCount - offset)
                }
                if written < 0 {
                    if errno == EINTR { continue }
                    throw MediaDraftProcessor.Failure.encodingFailed
                }
                offset += written
            }
            totalWritten += readCount
        }
        guard totalWritten > 0 else {
            throw MediaDraftProcessor.Failure.encodingFailed
        }
        succeeded = true
    }

    private static func stripOwnedFile(
        at inputURL: URL,
        preferredMediaType: String,
        directory: URL
    ) async throws -> StrippedVideo {
        let manager = FileManager.default
        let preferredType = fileType(for: preferredMediaType)
        let candidateTypes: [AVFileType] = preferredType == .mov ? [.mov, .mp4] : [.mp4, .mov]

        var lastError: Error = MediaDraftProcessor.Failure.encodingFailed
        for candidateType in candidateTypes {
            try Task.checkCancellation()
            let outputURL = directory
                .appendingPathComponent(UUID().uuidString, isDirectory: false)
                .appendingPathExtension(fileExtension(for: candidateType))
            defer { try? manager.removeItem(at: outputURL) }

            do {
                try await remuxStrippingMetadata(
                    sourceURL: inputURL,
                    outputURL: outputURL,
                    outputFileType: candidateType
                )
                try manager.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: outputURL.path
                )
                let strippedAsset = AVURLAsset(url: outputURL)
                let videoMetadata = await MediaVideoMetadata.metadata(for: strippedAsset)
                let mapped = try PickedMediaFile.mappedData(from: outputURL)
                guard !mapped.isEmpty else {
                    throw MediaDraftProcessor.Failure.encodingFailed
                }
                guard mapped.count <= MediaDraftProcessor.maxAttachmentBytes else {
                    throw MediaDraftProcessor.Failure.attachmentTooLarge(mapped.count)
                }
                return StrippedVideo(
                    data: mapped,
                    mediaType: mediaType(for: candidateType),
                    dim: videoMetadata.dim,
                    thumbnail: videoMetadata.thumbnail
                )
            } catch let failure as MediaDraftProcessor.Failure {
                if case .attachmentTooLarge = failure { throw failure }
                lastError = failure
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError is MediaDraftProcessor.Failure ? lastError : MediaDraftProcessor.Failure.encodingFailed
    }

    private static func remuxStrippingMetadata(
        sourceURL: URL,
        outputURL: URL,
        outputFileType: AVFileType
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let allTracks = try await asset.load(.tracks)
        // Copy only media tracks; timed `.metadata` and auxiliary tracks are dropped.
        let mediaTracks = allTracks.filter { $0.mediaType == .video || $0.mediaType == .audio }
        guard !mediaTracks.isEmpty else {
            throw MediaDraftProcessor.Failure.encodingFailed
        }

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: outputFileType)
        writer.metadata = []
        writer.shouldOptimizeForNetworkUse = true

        var trackConfigs: [(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)] = []

        for track in mediaTracks {
            try Task.checkCancellation()
            let formatDescriptions = try await track.load(.formatDescriptions)
            guard let formatHint = formatDescriptions.first else { continue }

            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { continue }

            let input = AVAssetWriterInput(
                mediaType: track.mediaType,
                outputSettings: nil,
                sourceFormatHint: formatHint
            )
            input.expectsMediaDataInRealTime = false
            input.metadata = []
            if track.mediaType == .video {
                input.transform = try await track.load(.preferredTransform)
                let timeScale = try await track.load(.naturalTimeScale)
                if timeScale > 0 {
                    input.mediaTimeScale = timeScale
                }
            }
            input.marksOutputTrackAsEnabled = try await track.load(.isEnabled)
            if let languageCode = try await track.load(.languageCode), !languageCode.isEmpty {
                input.languageCode = languageCode
            }
            if let extendedTag = try await track.load(.extendedLanguageTag), !extendedTag.isEmpty {
                input.extendedLanguageTag = extendedTag
            }

            guard writer.canAdd(input) else {
                throw MediaDraftProcessor.Failure.encodingFailed
            }
            reader.add(output)
            writer.add(input)
            trackConfigs.append((output: output, input: input))
        }

        guard !trackConfigs.isEmpty else {
            throw MediaDraftProcessor.Failure.encodingFailed
        }

        guard reader.startReading(), writer.startWriting() else {
            reader.cancelReading()
            writer.cancelWriting()
            throw MediaDraftProcessor.Failure.encodingFailed
        }

        var pairs: [PreparedTrackPair] = []
        var earliestPTS: CMTime?
        for config in trackConfigs {
            let first = config.output.copyNextSampleBuffer()
            if let first {
                let pts = CMSampleBufferGetPresentationTimeStamp(first)
                if pts.isValid, pts.isNumeric {
                    if let current = earliestPTS {
                        if CMTimeCompare(pts, current) < 0 { earliestPTS = pts }
                    } else {
                        earliestPTS = pts
                    }
                }
            }
            pairs.append(PreparedTrackPair(output: config.output, input: config.input, firstSample: first))
        }

        guard pairs.contains(where: { $0.firstSample != nil }) else {
            reader.cancelReading()
            writer.cancelWriting()
            throw MediaDraftProcessor.Failure.encodingFailed
        }

        writer.startSession(atSourceTime: earliestPTS ?? .zero)
        var activePairs: [(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)] = []
        for pair in pairs {
            if let first = pair.firstSample {
                guard pair.input.isReadyForMoreMediaData, pair.input.append(first) else {
                    reader.cancelReading()
                    writer.cancelWriting()
                    throw MediaDraftProcessor.Failure.encodingFailed
                }
                activePairs.append((output: pair.output, input: pair.input))
            } else {
                pair.input.markAsFinished()
            }
        }

        let outcome = await copyRemainingSamples(
            reader: reader,
            writer: writer,
            pairs: activePairs
        )
        switch outcome {
        case .cancelled:
            throw CancellationError()
        case .failed:
            throw MediaDraftProcessor.Failure.encodingFailed
        case .completed:
            break
        }

        guard reader.status == .completed else {
            reader.cancelReading()
            writer.cancelWriting()
            throw MediaDraftProcessor.Failure.encodingFailed
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw MediaDraftProcessor.Failure.encodingFailed
        }
    }

    enum SampleCopyOutcome: Equatable, Sendable {
        case completed
        case failed
        case cancelled
    }

    private struct SampleCopyState {
        var remaining: Int
        var finishedTracks: [Bool]
        var outcome: SampleCopyOutcome?
        var continuation: CheckedContinuation<SampleCopyOutcome, Never>?
        var cancelBeforeContinuation = false
    }

    static func copyRemainingSamples(
        reader: AVAssetReader,
        writer: AVAssetWriter,
        pairs: [(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)],
        appendSample: @escaping @Sendable (Int, AVAssetWriterInput, CMSampleBuffer) -> Bool = { _, input, sample in
            input.append(sample)
        }
    ) async -> SampleCopyOutcome {
        guard !pairs.isEmpty else { return Task.isCancelled ? .cancelled : .completed }
        let state = Mutex(SampleCopyState(
            remaining: pairs.count,
            finishedTracks: Array(repeating: false, count: pairs.count)
        ))

        @Sendable func abort(outcome: SampleCopyOutcome) {
            let continuation: CheckedContinuation<SampleCopyOutcome, Never>? = state.withLock { current in
                guard current.outcome == nil else { return nil }
                current.outcome = outcome
                let cont = current.continuation
                current.continuation = nil
                return cont
            }
            reader.cancelReading()
            writer.cancelWriting()
            continuation?.resume(returning: outcome)
        }

        @Sendable func finishTrack(_ index: Int, input: AVAssetWriterInput) {
            enum Action { case ignore, markOnly, complete(CheckedContinuation<SampleCopyOutcome, Never>?) }
            let action: Action = state.withLock { current in
                guard current.outcome == nil, !current.finishedTracks[index] else { return .ignore }
                current.finishedTracks[index] = true
                current.remaining -= 1
                if current.remaining == 0 {
                    current.outcome = .completed
                    let cont = current.continuation
                    current.continuation = nil
                    return .complete(cont)
                }
                return .markOnly
            }
            switch action {
            case .ignore:
                return
            case .markOnly:
                if writer.status == .writing {
                    input.markAsFinished()
                }
            case .complete(let continuation):
                if writer.status == .writing {
                    input.markAsFinished()
                }
                continuation?.resume(returning: .completed)
            }
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<SampleCopyOutcome, Never>) in
                let earlyOutcome: SampleCopyOutcome? = state.withLock { current in
                    if let existing = current.outcome {
                        return existing
                    }
                    if current.cancelBeforeContinuation || Task.isCancelled {
                        current.outcome = .cancelled
                        return .cancelled
                    }
                    current.continuation = continuation
                    return nil
                }
                if let earlyOutcome {
                    reader.cancelReading()
                    writer.cancelWriting()
                    continuation.resume(returning: earlyOutcome)
                    return
                }

                for (index, pair) in pairs.enumerated() {
                    let queue = DispatchQueue(
                        label: "dev.ipf.whitenoise.video-strip.\(index)",
                        qos: .userInitiated
                    )
                    let output = pair.output
                    let input = pair.input
                    input.requestMediaDataWhenReady(on: queue) {
                        while input.isReadyForMoreMediaData {
                            if state.withLock({ $0.outcome != nil }) {
                                return
                            }
                            if writer.status != .writing {
                                abort(outcome: .failed)
                                return
                            }
                            if let sample = output.copyNextSampleBuffer() {
                                if !appendSample(index, input, sample) {
                                    abort(outcome: .failed)
                                    return
                                }
                            } else {
                                finishTrack(index, input: input)
                                return
                            }
                        }
                    }
                }
            }
        } onCancel: {
            state.withLock { $0.cancelBeforeContinuation = true }
            abort(outcome: .cancelled)
        }
    }

    private static func prepareDirectory(_ directory: URL, now: Date) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        try? manager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path
        )
        MediaUploadSourceFiles.removeStale(in: directory, olderThan: staleAge, now: now)
    }

    private static func writeProtectedTempFile(
        data: Data,
        fileExtension: String,
        in directory: URL
    ) throws -> URL {
        let manager = FileManager.default
        let url = directory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
            .appendingPathExtension(fileExtension)
        guard manager.createFile(
            atPath: url.path,
            contents: nil,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        ) else {
            throw MediaDraftProcessor.Failure.encodingFailed
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            let chunkSize = 1024 * 1024
            var offset = data.startIndex
            while offset < data.endIndex {
                try Task.checkCancellation()
                let end = min(offset + chunkSize, data.endIndex)
                try handle.write(contentsOf: data[offset..<end])
                offset = end
            }
            try handle.close()
            return url
        } catch {
            try? manager.removeItem(at: url)
            throw error
        }
    }

    private static func fileType(for mediaType: String) -> AVFileType {
        MediaAttachmentPolicy.canonicalMediaType(mediaType) == "video/quicktime" ? .mov : .mp4
    }

    private static func fileExtension(for fileType: AVFileType) -> String {
        fileType == .mov ? "mov" : "mp4"
    }

    private static func mediaType(for fileType: AVFileType) -> String {
        fileType == .mov ? "video/quicktime" : "video/mp4"
    }
}

nonisolated private enum TemporaryMediaFile {
    static func withURL<T>(data: Data, fileExtension: String, _ work: (URL) -> T) -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhiteNoiseMediaWork", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        let url = directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
        defer { try? FileManager.default.removeItem(at: url) }
        return work(url)
    }

    static func withURL<T>(data: Data, fileExtension: String, _ work: (URL) async -> T) async -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhiteNoiseMediaWork", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        let url = directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
        defer { try? FileManager.default.removeItem(at: url) }
        return await work(url)
    }
}

nonisolated struct DecryptedMediaCacheEvictionPolicy: Equatable {
    let maxBytes: Int64
    let maxAge: TimeInterval

    static let media = DecryptedMediaCacheEvictionPolicy(
        maxBytes: 256 * 1024 * 1024,
        maxAge: 30 * 24 * 60 * 60
    )
    static let playback = DecryptedMediaCacheEvictionPolicy(
        maxBytes: 64 * 1024 * 1024,
        maxAge: 7 * 24 * 60 * 60
    )
}

nonisolated private enum DecryptedMediaCacheEvictor {
    private struct Entry {
        let url: URL
        let size: Int64
        let modifiedAt: Date
    }

    private static let minimumSweepInterval: TimeInterval = 5
    private static let sweepGate = DecryptedMediaCacheSweepGate(minimumInterval: minimumSweepInterval)

    static func touch(_ url: URL, at date: Date) {
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    static func trim(
        directory: URL,
        policy: DecryptedMediaCacheEvictionPolicy,
        preserving preservedURL: URL? = nil,
        now: Date = Date(),
        force: Bool = false
    ) {
        guard policy.maxBytes >= 0, policy.maxAge >= 0 else { return }
        guard sweepGate.shouldSweep(directory: directory, now: now, force: force) else { return }
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        var entries: [Entry] = []
        entries.reserveCapacity(urls.count)
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey,
                .contentModificationDateKey,
                .fileSizeKey,
            ]), values.isRegularFile == true else {
                continue
            }
            let size = Int64(max(0, values.fileSize ?? 0))
            let modifiedAt = values.contentModificationDate ?? .distantPast
            if preservedURL.map({ sameFile(url, $0) }) != true,
               now.timeIntervalSince(modifiedAt) > policy.maxAge
            {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            entries.append(Entry(url: url, size: size, modifiedAt: modifiedAt))
        }

        var totalSize = entries.reduce(Int64(0)) { $0 + $1.size }
        guard totalSize > policy.maxBytes else { return }
        for entry in entries.sorted(by: { lhs, rhs in
            if lhs.modifiedAt == rhs.modifiedAt {
                return lhs.url.lastPathComponent < rhs.url.lastPathComponent
            }
            return lhs.modifiedAt < rhs.modifiedAt
        }) where totalSize > policy.maxBytes {
            if preservedURL.map({ sameFile(entry.url, $0) }) == true { continue }
            do {
                try FileManager.default.removeItem(at: entry.url)
                totalSize -= entry.size
            } catch {
                continue
            }
        }
    }

    private static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }
}

// Thread-safe: every access to lastSweepByDirectory happens under `lock`.
// swiftlint:disable:next no_unchecked_sendable
nonisolated private final class DecryptedMediaCacheSweepGate: @unchecked Sendable {
    private let minimumInterval: TimeInterval
    private let lock = NSLock()
    private var lastSweepByDirectory: [String: Date] = [:]

    init(minimumInterval: TimeInterval) {
        self.minimumInterval = minimumInterval
    }

    func shouldSweep(directory: URL, now: Date, force: Bool) -> Bool {
        let key = directory.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        if force {
            lastSweepByDirectory[key] = now
            return true
        }
        if let lastSweep = lastSweepByDirectory[key] {
            let elapsed = now.timeIntervalSince(lastSweep)
            if elapsed >= 0, elapsed < minimumInterval {
                return false
            }
        }
        lastSweepByDirectory[key] = now
        return true
    }
}

nonisolated enum MediaPlaybackFileStore {
    private static let protectedAttributes: [FileAttributeKey: Any] = [
        .protectionKey: FileProtectionType.complete
    ]

    /// Runs the synchronous content-addressed store/write/trim off the MainActor
    /// so media open never blocks the UI thread (#351). `MessageMediaAttachment`
    /// is not `Sendable`, so only its content-addressed inputs cross into the
    /// detached task, which reconstructs a minimal item for the synchronous core.
    static func fileURL(
        for item: MessageMediaAttachment,
        data: Data,
        producerEpoch: Int? = nil
    ) async -> URL? {
        guard let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let reference = item.reference
        let mediaType = item.mediaType
        let fileName = item.fileName
        let id = item.id
        return await Task.detached(priority: .utility) {
            let coreItem = MessageMediaAttachment(
                id: id,
                reference: reference,
                fileName: fileName,
                mediaType: mediaType,
                dim: nil,
                localData: nil
            )
            return fileURL(
                for: coreItem,
                data: data,
                cachesDirectory: cachesDirectory,
                mediaPolicy: .media,
                playbackPolicy: .playback,
                now: Date(),
                producerEpoch: producerEpoch
            )
        }.value
    }

    static func fileURL(
        for item: MessageMediaAttachment,
        data: Data,
        cachesDirectory: URL,
        mediaPolicy: DecryptedMediaCacheEvictionPolicy,
        playbackPolicy: DecryptedMediaCacheEvictionPolicy,
        now: Date = Date(),
        producerEpoch: Int? = nil
    ) -> URL? {
        if let reference = item.reference,
           let cachedURL = MessageMediaCache.cacheURL(for: reference, cachesDirectory: cachesDirectory)
        {
            MessageMediaCache.store(
                data,
                for: reference,
                cachesDirectory: cachesDirectory,
                policy: mediaPolicy,
                now: now,
                producerGeneration: producerEpoch
            )
            return FileManager.default.fileExists(atPath: cachedURL.path) ? cachedURL : nil
        }

        let fileExtension = MediaAttachmentPolicy.fileExtension(for: item.mediaType, fileName: item.fileName)
        let directory = cachesDirectory.appendingPathComponent("EncryptedMediaPlayback", isDirectory: true)
        let url = directory.appendingPathComponent("\(sha256Hex(of: data)).\(fileExtension)")
        // Same critical section as the display cache: stale producers are
        // rejected before writing and no write interleaves with a purge.
        let stored: Bool = MessageMediaCache.purgeGeneration.withLock { generation in
            if let producerEpoch, producerEpoch != generation { return false }
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: protectedAttributes
                )
                try? FileManager.default.setAttributes(protectedAttributes, ofItemAtPath: directory.path)
                if !FileManager.default.fileExists(atPath: url.path) {
                    try data.write(to: url, options: [.atomic, .completeFileProtection])
                    try? FileManager.default.setAttributes(protectedAttributes, ofItemAtPath: url.path)
                }
                return true
            } catch {
                return false
            }
        }
        guard stored else { return nil }
        DecryptedMediaCacheEvictor.touch(url, at: now)
        DecryptedMediaCacheEvictor.trim(
            directory: directory,
            policy: playbackPolicy,
            preserving: url,
            now: now
        )
        return url
    }

    private static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

nonisolated enum MessageMediaCache {
    private static let protectedAttributes: [FileAttributeKey: Any] = [
        .protectionKey: FileProtectionType.complete
    ]

    /// Reads the decrypted-media cache off the MainActor so cache hits never
    /// block the UI thread on `Data(contentsOf:)` plus the eviction sweep (#351).
    static func cachedData(for reference: MediaAttachmentReferenceFfi) async -> Data? {
        guard let cachesDirectory = defaultCachesDirectory else { return nil }
        return await Task.detached(priority: .utility) {
            cachedData(for: reference, cachesDirectory: cachesDirectory)
        }.value
    }

    static func cachedData(
        for reference: MediaAttachmentReferenceFfi,
        cachesDirectory: URL,
        policy: DecryptedMediaCacheEvictionPolicy = .media,
        now: Date = Date()
    ) -> Data? {
        guard let url = cacheURL(for: reference, cachesDirectory: cachesDirectory) else { return nil }
        let directory = url.deletingLastPathComponent()
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let modifiedAt = attributes[.modificationDate] as? Date,
           now.timeIntervalSince(modifiedAt) > policy.maxAge
        {
            try? FileManager.default.removeItem(at: url)
            DecryptedMediaCacheEvictor.trim(directory: directory, policy: policy, now: now)
            return nil
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        DecryptedMediaCacheEvictor.touch(url, at: now)
        DecryptedMediaCacheEvictor.trim(directory: directory, policy: policy, preserving: url, now: now)
        return data
    }

    /// Writes the decrypted plaintext to the cache off the MainActor so the
    /// `data.write(to:)` and eviction sweep never block the UI thread (#351).
    static func store(
        _ data: Data,
        for reference: MediaAttachmentReferenceFfi,
        producerGeneration: Int? = nil
    ) async {
        guard let cachesDirectory = defaultCachesDirectory else { return }
        await Task.detached(priority: .utility) {
            store(
                data,
                for: reference,
                cachesDirectory: cachesDirectory,
                producerGeneration: producerGeneration
            )
        }.value
    }

    static func store(
        _ data: Data,
        for reference: MediaAttachmentReferenceFfi,
        cachesDirectory: URL,
        policy: DecryptedMediaCacheEvictionPolicy = .media,
        now: Date = Date(),
        producerGeneration: Int? = nil
    ) {
        guard let url = cacheURL(for: reference, cachesDirectory: cachesDirectory) else { return }
        let directory = url.deletingLastPathComponent()
        // The write happens inside the purge's own critical section: a stale
        // producer (bytes obtained before a wipe) is rejected before touching
        // the filesystem, and no write can interleave with directory removal.
        let stored: Bool = purgeGeneration.withLock { generation in
            if let producerGeneration, producerGeneration != generation { return false }
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: protectedAttributes
                )
                try? FileManager.default.setAttributes(protectedAttributes, ofItemAtPath: directory.path)
                try data.write(to: url, options: [.atomic, .completeFileProtection])
                try? FileManager.default.setAttributes(protectedAttributes, ofItemAtPath: url.path)
                return true
            } catch {
                return false
            }
        }
        guard stored else { return }
        DecryptedMediaCacheEvictor.touch(url, at: now)
        DecryptedMediaCacheEvictor.trim(
            directory: directory,
            policy: policy,
            preserving: url,
            now: now
        )
    }

    /// Removes cached decrypted plaintext when a caller has ciphertext hashes
    /// plus the corresponding media references. Cache files are keyed by the
    /// references' plaintext hashes, so both inputs are needed for this path.
    static func removeCachedData(
        forCiphertextHashes hashes: Set<String>,
        in references: [MediaAttachmentReferenceFfi]
    ) async {
        guard !hashes.isEmpty, let cachesDirectory = defaultCachesDirectory else { return }
        await Task.detached(priority: .utility) {
            removeCachedData(forCiphertextHashes: hashes, in: references, cachesDirectory: cachesDirectory)
        }.value
    }

    /// Directly evicts content-addressed plaintext files reported by Marmot's
    /// secure-prune result, avoiding a pre-prune `listMedia` scan.
    @discardableResult
    static func removeCachedData(forPlaintextHashes hashes: Set<String>) async -> Bool {
        guard !hashes.isEmpty else { return true }
        guard let cachesDirectory = defaultCachesDirectory else { return false }
        return await Task.detached(priority: .utility) {
            removeCachedData(forPlaintextHashes: hashes, cachesDirectory: cachesDirectory)
        }.value
    }

    static let decryptedMediaDirectoryNames = ["EncryptedMedia", "EncryptedMediaPlayback"]

    /// Bumped by a purge; a store that straddles the bump removes its own
    /// file so an in-flight decrypt can't quietly resurrect plaintext the
    /// wipe just promised was gone.
    static let purgeGeneration = Mutex(0)

    /// Destructive sign-out removes every decrypted plaintext copy — the
    /// content-addressed display cache and the playback store. The wipe's
    /// "removed from this device" promise covers media the user has viewed;
    /// age/size eviction alone can leave plaintext behind indefinitely.
    /// Returns whether both directories are verifiably gone, so the caller
    /// can report an incomplete wipe instead of assuming success.
    @discardableResult
    static func purgeAllDecryptedMedia() async -> Bool {
        guard let cachesDirectory = defaultCachesDirectory else { return false }
        return await Task.detached(priority: .utility) {
            purgeAllDecryptedMedia(cachesDirectory: cachesDirectory)
        }.value
    }

    /// The bump and the removal share one critical section with every cache
    /// write, so no writer can interleave with the purge — generation checks
    /// alone left a window where a write could land between removal and a
    /// later bump and survive.
    static func purgeAllDecryptedMedia(cachesDirectory: URL) -> Bool {
        purgeGeneration.withLock { generation in
            generation += 1
            var allRemoved = true
            for name in decryptedMediaDirectoryNames {
                let directory = cachesDirectory.appendingPathComponent(name, isDirectory: true)
                try? FileManager.default.removeItem(at: directory)
                if FileManager.default.fileExists(atPath: directory.path) {
                    allRemoved = false
                }
            }
            return allRemoved
        }
    }

    /// Captured by producers BEFORE the async gap that yields their bytes
    /// (cache read, download, upload round-trip); the write rejects a stale
    /// epoch before touching the filesystem.
    static func currentProducerEpoch() -> Int {
        purgeGeneration.withLock { $0 }
    }

    static func removeCachedData(
        forCiphertextHashes hashes: Set<String>,
        in references: [MediaAttachmentReferenceFfi],
        cachesDirectory: URL
    ) {
        purgeGeneration.withLock { generation in
            // Invalidate every producer that began before this deletion, then
            // remove under the same lock used by stores. No in-flight decrypt
            // can recreate plaintext after the delete operation returns.
            generation += 1
            removeCachedDataUnlocked(
                forCiphertextHashes: hashes,
                in: references,
                cachesDirectory: cachesDirectory
            )
        }
    }

    @discardableResult
    static func removeCachedData(
        forPlaintextHashes hashes: Set<String>,
        cachesDirectory: URL
    ) -> Bool {
        let validHashes = Set(hashes.lazy.map { $0.lowercased() }.filter {
            $0.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
        })
        guard !validHashes.isEmpty else { return true }
        return purgeGeneration.withLock { generation in
            generation += 1
            var allRemoved = true
            for directoryName in decryptedMediaDirectoryNames {
                let directory = cachesDirectory.appendingPathComponent(directoryName, isDirectory: true)
                let existing: [URL]
                do {
                    existing = try FileManager.default.contentsOfDirectory(
                        at: directory,
                        includingPropertiesForKeys: nil
                    )
                } catch {
                    if !isNoSuchFileError(error) {
                        allRemoved = false
                    }
                    continue
                }
                for file in existing {
                    let stem = file.deletingPathExtension().lastPathComponent.lowercased()
                    if validHashes.contains(stem) {
                        do {
                            try FileManager.default.removeItem(at: file)
                        } catch {
                            if !isNoSuchFileError(error) {
                                allRemoved = false
                            }
                        }
                        if FileManager.default.fileExists(atPath: file.path) {
                            allRemoved = false
                        }
                    }
                }
            }
            return allRemoved
        }
    }

    private static func isNoSuchFileError(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError
    }

    private static func removeCachedDataUnlocked(
        forCiphertextHashes hashes: Set<String>,
        in references: [MediaAttachmentReferenceFfi],
        cachesDirectory: URL
    ) {
        let directory = cachesDirectory.appendingPathComponent("EncryptedMedia", isDirectory: true)
        let existing = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        for reference in references where hashes.contains(reference.ciphertextSha256.lowercased()) {
            // Every file sharing the hash stem goes, not just the current
            // media-type name: older builds keyed by peer filename extension,
            // and expired plaintext must not survive under a legacy name.
            let hash = reference.plaintextSha256.lowercased()
            guard hash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else { continue }
            for file in existing where file.lastPathComponent.hasPrefix("\(hash).") {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    static func cacheURL(for reference: MediaAttachmentReferenceFfi) -> URL? {
        guard let cachesDirectory = defaultCachesDirectory else { return nil }
        return cacheURL(for: reference, cachesDirectory: cachesDirectory)
    }

    static func cacheURL(for reference: MediaAttachmentReferenceFfi, cachesDirectory: URL) -> URL? {
        let hash = reference.plaintextSha256.lowercased()
        guard hash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            return nil
        }
        // Content-addressed: the extension comes from the media type alone.
        // Folding in the peer-controlled filename made pic.jpg and pic.jpeg
        // of identical plaintext miss each other's cache entries, forcing a
        // redundant download + decrypt and a duplicate plaintext copy.
        return cachesDirectory
            .appendingPathComponent("EncryptedMedia", isDirectory: true)
            .appendingPathComponent("\(hash).\(MediaAttachmentPolicy.fileExtension(for: reference.mediaType))")
    }

    private static var defaultCachesDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    }
}

nonisolated struct AttachmentSourceHint: Hashable, Sendable {
    let messageID: String
    let slot: UInt32
}
