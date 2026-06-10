import Foundation
import MarmotKit
import UIKit

struct MessageMediaAttachment: Identifiable, Hashable {
    let id: String
    let reference: MediaAttachmentReferenceFfi?
    let fileName: String
    let mediaType: String
    let dim: String?
    let localData: Data?

    var isImage: Bool {
        mediaType.lowercased().hasPrefix("image/")
    }

    static func displayItems(from references: [MediaAttachmentReferenceFfi]) -> [MessageMediaAttachment] {
        references.enumerated().map { index, reference in
            MessageMediaAttachment(
                id: "\(reference.plaintextSha256):\(reference.sourceEpoch):\(index)",
                reference: reference,
                fileName: reference.fileName,
                mediaType: reference.mediaType,
                dim: reference.dim,
                localData: nil
            )
        }
    }
}

struct MediaDraftAttachment: Identifiable, Hashable {
    let id: UUID
    let fileName: String
    let mediaType: String
    let data: Data
    let dim: String?

    init(id: UUID = UUID(), fileName: String, mediaType: String, data: Data, dim: String?) {
        self.id = id
        self.fileName = fileName
        self.mediaType = mediaType
        self.data = data
        self.dim = dim
    }

    var uploadRequest: MediaUploadAttachmentRequestFfi {
        MediaUploadAttachmentRequestFfi(
            fileName: fileName,
            mediaType: mediaType,
            plaintext: data,
            dim: dim,
            thumbhash: nil
        )
    }

    var displayItem: MessageMediaAttachment {
        MessageMediaAttachment(
            id: id.uuidString,
            reference: nil,
            fileName: fileName,
            mediaType: mediaType,
            dim: dim,
            localData: data
        )
    }
}

enum MediaDraftProcessor {
    static let maxAttachmentCount = 10
    static let maxLongEdge: CGFloat = 2048
    static let maxAttachmentBytes = 10 * 1024 * 1024

    enum Failure: LocalizedError {
        case unsupportedImage
        case encodingFailed
        case attachmentTooLarge(Int)

        var errorDescription: String? {
            switch self {
            case .unsupportedImage:
                return L10n.string("That image could not be opened.")
            case .encodingFailed:
                return L10n.string("That image could not be prepared.")
            case .attachmentTooLarge:
                return L10n.string("That image is too large to send.")
            }
        }
    }

    static func attachment(from data: Data, fileName: String?) throws -> MediaDraftAttachment {
        guard let image = UIImage(data: data) else {
            throw Failure.unsupportedImage
        }
        return try attachment(from: image, fileName: fileName)
    }

    static func attachment(from image: UIImage, fileName: String?) throws -> MediaDraftAttachment {
        let normalized = normalizedImage(image)
        let encoded = try encodeJPEG(normalized)
        guard encoded.count <= maxAttachmentBytes else {
            throw Failure.attachmentTooLarge(encoded.count)
        }
        let width = max(1, Int(normalized.size.width.rounded()))
        let height = max(1, Int(normalized.size.height.rounded()))
        return MediaDraftAttachment(
            fileName: sanitizedFileName(fileName),
            mediaType: "image/jpeg",
            data: encoded,
            dim: "\(width)x\(height)"
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
            if let data = image.jpegData(compressionQuality: quality), data.count <= maxAttachmentBytes {
                return data
            }
        }
        guard let data = image.jpegData(compressionQuality: 0.52) else {
            throw Failure.encodingFailed
        }
        return data
    }

    private static func sanitizedFileName(_ fileName: String?) -> String {
        let base = fileName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/")
            .last
            .map(String.init)
        let stem = base?
            .replacingOccurrences(of: #"[^A-Za-z0-9._-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        guard let stem, !stem.isEmpty else {
            return "photo-\(Int(Date().timeIntervalSince1970)).jpg"
        }
        if stem.lowercased().hasSuffix(".jpg") || stem.lowercased().hasSuffix(".jpeg") {
            return stem
        }
        return "\(stem).jpg"
    }
}

enum MessageMediaCache {
    static func cachedData(for reference: MediaAttachmentReferenceFfi) -> Data? {
        guard let url = cacheURL(for: reference) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func store(_ data: Data, for reference: MediaAttachmentReferenceFfi) {
        guard let url = cacheURL(for: reference) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: [.atomic])
    }

    private static func cacheURL(for reference: MediaAttachmentReferenceFfi) -> URL? {
        let hash = reference.plaintextSha256.lowercased()
        guard hash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("EncryptedMedia", isDirectory: true)
            .appendingPathComponent("\(hash).\(fileExtension(for: reference.mediaType))")
    }

    private static func fileExtension(for mediaType: String) -> String {
        switch MessageSemantics.canonicalMediaType(mediaType) {
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/heic": return "heic"
        case "image/webp": return "webp"
        default: return "bin"
        }
    }
}
