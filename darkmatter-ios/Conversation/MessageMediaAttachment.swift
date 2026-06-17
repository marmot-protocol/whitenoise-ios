import Foundation
import AVFoundation
import MarmotKit
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
        if let fileName,
           let fileExtension = fileName.split(separator: ".").last.map(String.init),
           MediaAttachmentPolicy.supportedDocumentExtensions.contains(fileExtension.lowercased())
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
        "text/csv",
        "text/json",
        "text/plain",
        "text/rtf",
    ]

    static let supportedDocumentExtensions: Set<String> = [
        "csv",
        "doc",
        "docx",
        "json",
        "pdf",
        "ppt",
        "pptx",
        "rtf",
        "txt",
        "xls",
        "xlsx",
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
    /// darkmatter-ios#242 / #233). SVG is treated as unsupported so it never
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
        if let fileName,
           let fileExtension = fileName.split(separator: ".").last.map(String.init)
        {
            return supportedDocumentExtensions.contains(fileExtension.lowercased())
        }
        return false
    }

    static func mediaType(typeIdentifier: String?, fileName: String?, fallbackKind: MediaAttachmentKind?) -> String? {
        if let typeIdentifier,
           let type = UTType(typeIdentifier),
           let mediaType = type.preferredMIMEType
        {
            return canonicalMediaType(mediaType)
        }
        if let fileName,
           let fileExtension = fileName.split(separator: ".").last.map(String.init),
           let mediaType = mediaType(forFileExtension: fileExtension)
        {
            return canonicalMediaType(mediaType)
        }
        switch fallbackKind {
        case .video: return "video/mp4"
        case .audio: return "audio/mp4"
        case .image: return "image/jpeg"
        case .document, .unsupported, .none: return nil
        }
    }

    static func mediaType(forFileExtension fileExtension: String) -> String? {
        let lower = fileExtension.lowercased()
        switch lower {
        case "m4a": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "mov": return "video/quicktime"
        case "mp4", "m4v": return "video/mp4"
        case "txt": return "text/plain"
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
        default:
            return UTType(filenameExtension: lower)?.preferredMIMEType
        }
    }

    static func fileExtension(for mediaType: String, fileName: String? = nil) -> String {
        if let fileName,
           let ext = fileName.split(separator: ".").last.map(String.init),
           !ext.isEmpty
        {
            return ext.lowercased()
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
        case "application/msword": return "doc"
        case "application/vnd.openxmlformats-officedocument.wordprocessingml.document": return "docx"
        case "application/vnd.ms-excel": return "xls"
        case "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": return "xlsx"
        case "application/vnd.ms-powerpoint": return "ppt"
        case "application/vnd.openxmlformats-officedocument.presentationml.presentation": return "pptx"
        default: return "bin"
        }
    }
}

nonisolated struct MessageMediaAttachment: Identifiable, Hashable {
    let id: String
    let reference: MediaAttachmentReferenceFfi?
    let fileName: String
    let mediaType: String
    let dim: String?
    let localData: Data?
    let thumbnail: UIImage?
    let durationSeconds: Double?
    let waveformSamples: [CGFloat]

    init(
        id: String,
        reference: MediaAttachmentReferenceFfi?,
        fileName: String,
        mediaType: String,
        dim: String?,
        localData: Data?,
        thumbnail: UIImage? = nil,
        durationSeconds: Double? = nil,
        waveformSamples: [CGFloat] = []
    ) {
        self.id = id
        self.reference = reference
        self.fileName = fileName
        self.mediaType = mediaType
        self.dim = dim
        self.localData = localData
        self.thumbnail = thumbnail
        self.durationSeconds = durationSeconds
        self.waveformSamples = waveformSamples
    }

    var isImage: Bool {
        MediaAttachmentPolicy.isDecodableImageMediaType(mediaType)
    }

    var isVideo: Bool {
        MediaAttachmentPolicy.canonicalMediaType(mediaType).hasPrefix("video/")
    }

    var isAudio: Bool {
        MediaAttachmentPolicy.canonicalMediaType(mediaType).hasPrefix("audio/")
    }

    var isDocument: Bool {
        MediaAttachmentKind.classify(mediaType: mediaType, fileName: fileName) == .document
    }

    var kind: MediaAttachmentKind {
        MediaAttachmentKind.classify(mediaType: mediaType, fileName: fileName)
    }

    static func displayItems(
        from references: [MediaAttachmentReferenceFfi],
        ownerId: String
    ) -> [MessageMediaAttachment] {
        references.enumerated().map { index, reference in
            let id = [
                ownerId,
                reference.plaintextSha256,
                String(reference.sourceEpoch),
                String(index),
            ].joined(separator: ":")
            return MessageMediaAttachment(
                id: id,
                reference: reference,
                fileName: reference.fileName,
                mediaType: reference.mediaType,
                dim: reference.dim,
                localData: nil,
                thumbnail: nil,
                durationSeconds: nil,
                waveformSamples: []
            )
        }
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

nonisolated enum MediaDraftProcessor {
    static let maxAttachmentCount = 10
    static let maxLongEdge: CGFloat = 2048
    static let maxImageAttachmentBytes = 10 * 1024 * 1024
    static let maxAttachmentBytes = 50 * 1024 * 1024
    static let draftThumbnailPixelSize: CGFloat = 160

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

    private struct SendableAttachment: @unchecked Sendable {
        let attachment: MediaDraftAttachment
    }

    private struct SendableImage: @unchecked Sendable {
        let image: UIImage
    }

    static func preparedAttachment(from data: Data, fileName: String?) async throws -> MediaDraftAttachment {
        try await preparedAttachment(from: data, fileName: fileName, typeIdentifier: nil)
    }

    static func preparedAttachment(
        from data: Data,
        fileName: String?,
        typeIdentifier: String?
    ) async throws -> MediaDraftAttachment {
        let prepared = try await Task.detached(priority: .userInitiated) { () async throws -> SendableAttachment in
            try await SendableAttachment(attachment: preparedAttachmentValue(
                from: data,
                fileName: fileName,
                typeIdentifier: typeIdentifier
            ))
        }.value
        return prepared.attachment
    }

    static func preparedAttachment(fromFileURL url: URL) async throws -> MediaDraftAttachment {
        let prepared = try await Task.detached(priority: .userInitiated) { () async throws -> SendableAttachment in
            let resourceValues = try url.resourceValues(forKeys: [.contentTypeKey, .nameKey])
            let data = try Data(contentsOf: url)
            return try await SendableAttachment(attachment: preparedAttachmentValue(
                from: data,
                fileName: resourceValues.name ?? url.lastPathComponent,
                typeIdentifier: resourceValues.contentType?.identifier
            ))
        }.value
        return prepared.attachment
    }

    static func preparedVoiceAttachment(from recording: VoiceRecordingResult) async throws -> MediaDraftAttachment {
        let prepared = try await Task.detached(priority: .userInitiated) { () throws -> SendableAttachment in
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
            return SendableAttachment(attachment: MediaDraftAttachment(
                fileName: fileName,
                mediaType: "audio/mp4",
                data: data,
                dim: nil,
                durationSeconds: recording.durationSeconds,
                waveformSamples: MediaWaveformAnalyzer.normalized(recording.waveformSamples)
            ))
        }.value
        return prepared.attachment
    }

    static func preparedAttachment(from image: UIImage, fileName: String?) async throws -> MediaDraftAttachment {
        let sendableImage = SendableImage(image: image)
        let prepared = try await Task.detached(priority: .userInitiated) { () throws -> SendableAttachment in
            try SendableAttachment(attachment: attachment(from: sendableImage.image, fileName: fileName))
        }.value
        return prepared.attachment
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
        let mediaType = MediaAttachmentPolicy.mediaType(
            typeIdentifier: typeIdentifier,
            fileName: fileName,
            fallbackKind: kind
        )
        let videoMetadata: MediaVideoMetadata.Metadata?
        if kind == .video,
           let mediaType,
           MediaAttachmentPolicy.isSupported(mediaType: mediaType, fileName: fileName),
           data.count <= maxAttachmentBytes
        {
            videoMetadata = await MediaVideoMetadata.metadata(from: data, mediaType: mediaType)
        } else {
            videoMetadata = nil
        }
        return try attachment(
            from: data,
            fileName: fileName,
            typeIdentifier: typeIdentifier,
            videoMetadata: videoMetadata
        )
    }

    private static func attachment(
        from data: Data,
        fileName: String?,
        typeIdentifier: String?,
        videoMetadata: MediaVideoMetadata.Metadata?
    ) throws -> MediaDraftAttachment {
        if let typeIdentifier,
           let type = UTType(typeIdentifier),
           type.conforms(to: .image)
        {
            guard let image = UIImage(data: data) else {
                throw Failure.unsupportedImage
            }
            return try attachment(from: image, fileName: fileName)
        }

        if typeIdentifier == nil, UIImage(data: data) != nil {
            return try attachment(from: data, fileName: fileName, typeIdentifier: UTType.image.identifier)
        }

        let kind = kind(for: typeIdentifier, fileName: fileName)
        if kind == .image {
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

    private static func kind(for typeIdentifier: String?, fileName: String?) -> MediaAttachmentKind {
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
        if let fileName,
           let fileExtension = fileName.split(separator: ".").last.map(String.init),
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
        guard let image = UIImage(data: data) else {
            throw Failure.unsupportedImage
        }
        return try attachment(from: image, fileName: fileName)
    }

    static func attachment(from image: UIImage, fileName: String?) throws -> MediaDraftAttachment {
        let normalized = normalizedImage(image)
        let encoded = try encodeJPEG(normalized)
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

    private static func normalizedImage(_ image: UIImage) -> UIImage {
        // Canvas must use the oriented size: cgImage dimensions are pre-EXIF-rotation
        // (camera portraits are landscape bitmaps tagged .right), while draw(in:)
        // renders rotation-applied content. Mixing the two squashes the photo.
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

    private static func encodeJPEG(_ image: UIImage) throws -> Data {
        for quality in [0.86, 0.74, 0.62] as [CGFloat] {
            if let data = image.jpegData(compressionQuality: quality), data.count <= maxImageAttachmentBytes {
                return data
            }
        }
        guard let data = image.jpegData(compressionQuality: 0.52) else {
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
    /// peer-controlled and decodes far larger than the compressed 50 MB cap, so
    /// a whole-file buffer is remotely triggerable OOM (see darkmatter-ios#208).
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

nonisolated private enum MediaVideoMetadata {
    struct Metadata {
        let dim: String?
        let thumbnail: UIImage?
    }

    static func metadata(from data: Data, mediaType: String) async -> Metadata {
        await TemporaryMediaFile.withURL(data: data, fileExtension: MediaAttachmentPolicy.fileExtension(for: mediaType)) { url in
            let asset = AVURLAsset(url: url)
            let dim = await dimensions(for: asset)
            let thumbnail = await thumbnail(for: asset)
            return Metadata(dim: dim, thumbnail: thumbnail)
        }
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
            let width = max(1, Int(abs(transformed.width).rounded()))
            let height = max(1, Int(abs(transformed.height).rounded()))
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

nonisolated private enum TemporaryMediaFile {
    static func withURL<T>(data: Data, fileExtension: String, _ work: (URL) -> T) -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DarkMatterMediaWork", isDirectory: true)
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
            .appendingPathComponent("DarkMatterMediaWork", isDirectory: true)
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

enum MediaPlaybackFileStore {
    private static let protectedAttributes: [FileAttributeKey: Any] = [
        .protectionKey: FileProtectionType.complete
    ]

    static func fileURL(for item: MessageMediaAttachment, data: Data) -> URL? {
        guard let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let fileExtension = MediaAttachmentPolicy.fileExtension(for: item.mediaType, fileName: item.fileName)
        let rawName = item.reference?.plaintextSha256 ?? item.id
        let safeName = rawName
            .replacingOccurrences(of: #"[^A-Za-z0-9._-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        let directory = cachesDirectory.appendingPathComponent("EncryptedMediaPlayback", isDirectory: true)
        let url = directory.appendingPathComponent("\(safeName.isEmpty ? UUID().uuidString : safeName).\(fileExtension)")
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
            return url
        } catch {
            return nil
        }
    }
}

enum MessageMediaCache {
    private static let protectedAttributes: [FileAttributeKey: Any] = [
        .protectionKey: FileProtectionType.complete
    ]

    static func cachedData(for reference: MediaAttachmentReferenceFfi) -> Data? {
        guard let url = cacheURL(for: reference) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func store(_ data: Data, for reference: MediaAttachmentReferenceFfi) {
        guard let cachesDirectory = defaultCachesDirectory else { return }
        store(data, for: reference, cachesDirectory: cachesDirectory)
    }

    static func store(_ data: Data, for reference: MediaAttachmentReferenceFfi, cachesDirectory: URL) {
        guard let url = cacheURL(for: reference, cachesDirectory: cachesDirectory) else { return }
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: protectedAttributes
            )
            try? FileManager.default.setAttributes(protectedAttributes, ofItemAtPath: directory.path)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            try? FileManager.default.setAttributes(protectedAttributes, ofItemAtPath: url.path)
        } catch {
            return
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
        return cachesDirectory
            .appendingPathComponent("EncryptedMedia", isDirectory: true)
            .appendingPathComponent("\(hash).\(MediaAttachmentPolicy.fileExtension(for: reference.mediaType, fileName: reference.fileName))")
    }

    private static var defaultCachesDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    }
}
