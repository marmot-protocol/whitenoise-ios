import Foundation
import MarmotKit
import Observation

/// Which MDK upload API carries a batch of draft attachments.
nonisolated enum MediaUploadRoute: Equatable, Sendable {
    /// `uploadMedia`: plaintext crosses the FFI as a byte array.
    case bytes
    /// `uploadMediaFiles`: MDK streams each attachment from a source file, with
    /// progress, explicit cancellation and no fixed worker-response timeout.
    case files

    static let fileBackedThresholdBytes = 4 * 1024 * 1024

    /// Videos and documents always go file-backed; anything else only once the
    /// batch is large. The whole batch takes one route.
    static func route(kinds: [MediaAttachmentKind], byteCounts: [Int]) -> MediaUploadRoute {
        if kinds.contains(where: { $0 == .video || $0 == .document }) { return .files }
        var total = 0
        for count in byteCounts {
            let (sum, overflow) = total.addingReportingOverflow(max(0, count))
            if overflow { return .files }
            total = sum
        }
        return total >= fileBackedThresholdBytes ? .files : .bytes
    }

    static func route(for attachments: [MediaDraftAttachment]) -> MediaUploadRoute {
        route(kinds: attachments.map(\.kind), byteCounts: attachments.map(\.data.count))
    }
}

nonisolated enum MediaFileUploadFailure: LocalizedError, Equatable, Sendable {
    /// The batch's ciphertext would exceed `maxFileMediaCiphertextBytes()`.
    case exceedsTransferLimit(attachmentCount: Int)
    /// A protected source file could not be written.
    case sourceUnavailable
    /// The operation's transfer control was cancelled before MDK finished.
    case cancelled

    var errorDescription: String? {
        switch self {
        case .exceedsTransferLimit(let count):
            return count > 1
                ? L10n.string("These attachments are too large to send together.")
                : L10n.string("That attachment is too large to send.")
        case .sourceUnavailable:
            return L10n.string("That attachment could not be prepared.")
        case .cancelled:
            return L10n.string("Cancelled")
        }
    }
}

nonisolated enum MediaFileUploadLimit {
    static let aeadTagBytes: UInt64 = 16

    /// Ciphertext bytes MDK counts against its batch bound: each attachment's
    /// plaintext plus its AEAD tag. Nil when the sum overflows.
    static func ciphertextBytes(plaintextByteCounts: [Int]) -> UInt64? {
        var total: UInt64 = 0
        for count in plaintextByteCounts {
            let (withBody, bodyOverflow) = total.addingReportingOverflow(UInt64(max(0, count)))
            let (withTag, tagOverflow) = withBody.addingReportingOverflow(aeadTagBytes)
            if bodyOverflow || tagOverflow { return nil }
            total = withTag
        }
        return total
    }

    static func validate(plaintextByteCounts: [Int], limit: UInt64) throws {
        guard let total = ciphertextBytes(plaintextByteCounts: plaintextByteCounts), total <= limit else {
            throw MediaFileUploadFailure.exceedsTransferLimit(attachmentCount: plaintextByteCounts.count)
        }
    }
}

nonisolated enum MediaFileUploadErrorMapping {
    /// MDK has no dedicated cancellation error; the operation's own control
    /// tells a requested cancellation apart from a failure.
    static func mapped(_ error: Error, cancellationRequested: Bool) -> Error {
        cancellationRequested ? MediaFileUploadFailure.cancelled : error
    }

    static func isCancellation(_ error: Error) -> Bool {
        (error as? MediaFileUploadFailure) == .cancelled
    }
}

nonisolated enum MediaFileUploadProgress {
    /// MDK 0.13 advances one attachment's counter through snapshot, encryption
    /// and transfer, each covering the whole file (transfer adds its AEAD tag).
    /// A batch reports only the furthest single file, so it stays indeterminate.
    static func fraction(processedBytes: UInt64, plaintextByteCounts: [Int]) -> Double? {
        guard plaintextByteCounts.count == 1, let count = plaintextByteCounts.first, count > 0 else { return nil }
        let total = 3 * (Double(count) + Double(MediaFileUploadLimit.aeadTagBytes))
        return min(1, max(0, Double(processedBytes) / total))
    }
}

/// Plaintext copies of draft attachments as regular, complete-protection files
/// that MDK can snapshot. They live only for one upload call.
nonisolated struct MediaUploadSourceFiles: Sendable {
    static let directoryName = "WhiteNoiseMediaUploads"
    static let staleAge: TimeInterval = 24 * 60 * 60
    private static let protectedAttributes: [FileAttributeKey: Any] = [
        .protectionKey: FileProtectionType.complete
    ]

    let urls: [URL]
    let requests: [MediaFileUploadAttachmentRequestFfi]

    static var defaultDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Writes each attachment off the MainActor. Removes everything it wrote
    /// if any write fails.
    static func stage(
        _ attachments: [MediaDraftAttachment],
        in directory: URL = defaultDirectory,
        now: Date = Date()
    ) async throws -> MediaUploadSourceFiles {
        try await Task.detached(priority: .userInitiated) {
            try stageSynchronously(attachments, in: directory, now: now)
        }.value
    }

    static func stageSynchronously(
        _ attachments: [MediaDraftAttachment],
        in directory: URL,
        now: Date
    ) throws -> MediaUploadSourceFiles {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: protectedAttributes)
            try? manager.setAttributes(protectedAttributes, ofItemAtPath: directory.path)
        } catch {
            throw MediaFileUploadFailure.sourceUnavailable
        }
        removeStale(in: directory, olderThan: staleAge, now: now)

        var urls: [URL] = []
        var requests: [MediaFileUploadAttachmentRequestFfi] = []
        do {
            for attachment in attachments {
                let url = directory.appendingPathComponent(UUID().uuidString, isDirectory: false)
                // Without overwriting: an existing entry, symlink included, fails the write.
                try attachment.data.write(to: url, options: [.withoutOverwriting, .completeFileProtection])
                urls.append(url)
                try? manager.setAttributes(protectedAttributes, ofItemAtPath: url.path)
                guard isRegularFile(at: url) else { throw MediaFileUploadFailure.sourceUnavailable }
                requests.append(MediaFileUploadAttachmentRequestFfi(
                    sourcePath: url.path,
                    expectedSize: UInt64(attachment.data.count),
                    fileName: attachment.fileName,
                    mediaType: attachment.mediaType,
                    dim: attachment.dim,
                    thumbhash: attachment.thumbhash
                ))
            }
        } catch {
            remove(urls)
            throw MediaFileUploadFailure.sourceUnavailable
        }
        return MediaUploadSourceFiles(urls: urls, requests: requests)
    }

    /// Call only after the MDK call that read these files has returned.
    func remove() async {
        let urls = urls
        await Task.detached(priority: .utility) { Self.remove(urls) }.value
    }

    static func remove(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// True only for a regular file; a symlink is reported as itself, not its target.
    static func isRegularFile(at url: URL) -> Bool {
        guard let type = try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType else {
            return false
        }
        return type == .typeRegular
    }

    /// Leftovers from an interrupted process; live uploads are much younger.
    static func removeStale(in directory: URL, olderThan age: TimeInterval, now: Date) {
        let manager = FileManager.default
        guard let children = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for child in children {
            let modified = (try? child.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modified, now.timeIntervalSince(modified) > age else { continue }
            try? manager.removeItem(at: child)
        }
    }
}

nonisolated enum MediaFileUploadRunner {
    /// Stages `attachments`, runs `upload` with one fresh control, and removes
    /// the source files once MDK has returned. Task cancellation cancels the
    /// control; a cancelled control surfaces as `MediaFileUploadFailure.cancelled`.
    static func run<Value: Sendable>(
        _ attachments: [MediaDraftAttachment],
        control: MediaFileTransferControlFfi,
        limit: UInt64,
        directory: URL = MediaUploadSourceFiles.defaultDirectory,
        upload: @escaping @Sendable ([MediaFileUploadAttachmentRequestFfi]) async throws -> Value
    ) async throws -> Value {
        try MediaFileUploadLimit.validate(plaintextByteCounts: attachments.map(\.data.count), limit: limit)
        return try await withTaskCancellationHandler {
            let sources = try await MediaUploadSourceFiles.stage(attachments, in: directory)
            do {
                let value = try await upload(sources.requests)
                await sources.remove()
                return value
            } catch {
                await sources.remove()
                throw MediaFileUploadErrorMapping.mapped(error, cancellationRequested: control.isCancelled())
            }
        } onCancel: {
            control.cancel()
        }
    }
}

/// Upload progress for the pending bubble, keyed by draft attachment id.
@Observable
@MainActor
final class MediaUploadProgressStore {
    static let pollInterval: Duration = .milliseconds(250)

    private var fractions: [String: Double] = [:]

    func fraction(forItemIds itemIds: [String]) -> Double? {
        guard itemIds.count == 1, let id = itemIds.first else { return nil }
        return fractions[id]
    }

    /// Polls `control` until the returned task is cancelled, then clears the entry.
    func track(_ attachments: [MediaDraftAttachment], control: MediaFileTransferControlFfi) -> Task<Void, Never> {
        let byteCounts = attachments.map(\.data.count)
        guard attachments.count == 1, let id = attachments.first?.id.uuidString else {
            return Task {}
        }
        return Task { [weak self] in
            while !Task.isCancelled {
                if let fraction = MediaFileUploadProgress.fraction(
                    processedBytes: control.processedBytes(),
                    plaintextByteCounts: byteCounts
                ), self?.fractions[id] != fraction {
                    self?.fractions[id] = fraction
                }
                try? await Task.sleep(for: Self.pollInterval)
            }
            self?.fractions[id] = nil
        }
    }
}
