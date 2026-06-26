import Foundation
import MarmotKit

/// Dedup key for an in-flight media download: a content-addressed media
/// reference normalized to lowercase hex.
struct MediaDownloadInFlightKey: Hashable {
    let version: String
    let plaintextSha256: String
    let ciphertextSha256: String
    let nonceHex: String

    init(reference: MediaAttachmentReferenceFfi) {
        self.version = reference.version
        self.plaintextSha256 = reference.plaintextSha256.lowercased()
        self.ciphertextSha256 = reference.ciphertextSha256.lowercased()
        self.nonceHex = reference.nonceHex.lowercased()
    }
}

/// Coalesces concurrent downloads of the same media reference so duplicate
/// thumbnail/gallery requests share one decrypt/download task.
@MainActor
final class MediaDownloadInFlightStore {
    private var tasks: [MediaDownloadInFlightKey: Task<Data, Error>] = [:]

    func data(
        for key: MediaDownloadInFlightKey,
        operation: @escaping @MainActor () async throws -> Data
    ) async throws -> Data {
        if let task = tasks[key] {
            return try await task.value
        }
        let task = Task { @MainActor in
            try await operation()
        }
        tasks[key] = task
        do {
            let data = try await task.value
            tasks[key] = nil
            return data
        } catch {
            tasks[key] = nil
            throw error
        }
    }
}

@MainActor
protocol ConversationMediaCacheAccessing {
    func cachedData(for reference: MediaAttachmentReferenceFfi) async -> Data?
    func store(_ data: Data, for reference: MediaAttachmentReferenceFfi) async
}

struct DefaultConversationMediaCache: ConversationMediaCacheAccessing {
    func cachedData(for reference: MediaAttachmentReferenceFfi) async -> Data? {
        await MessageMediaCache.cachedData(for: reference)
    }

    func store(_ data: Data, for reference: MediaAttachmentReferenceFfi) async {
        await MessageMediaCache.store(data, for: reference)
    }
}

/// Owns the conversation media download path: local-bytes/cache short-circuits,
/// then a deduplicated decrypt+download through Marmot with a write-back into the
/// decrypted-media cache. Extracted from `ConversationViewModel`; the group id and
/// active `AppState` are passed per call so this stays free of conversation state.
@MainActor
final class ConversationMediaDownloader {
    typealias DownloadMedia = @MainActor (
        _ client: MarmotClient,
        _ accountRef: String,
        _ groupIdHex: String,
        _ reference: MediaAttachmentReferenceFfi
    ) async throws -> MediaDownloadResultFfi

    private let inFlight = MediaDownloadInFlightStore()
    private let cache: ConversationMediaCacheAccessing
    private let downloadMedia: DownloadMedia

    init(
        cache: ConversationMediaCacheAccessing? = nil,
        downloadMedia: @escaping DownloadMedia = { client, accountRef, groupIdHex, reference in
            try await client.downloadMedia(
                accountRef: accountRef,
                groupIdHex: groupIdHex,
                reference: reference
            )
        }
    ) {
        self.cache = cache ?? DefaultConversationMediaCache()
        self.downloadMedia = downloadMedia
    }

    func data(for media: MessageMediaAttachment, groupIdHex: String, appState: AppState?) async throws -> Data {
        if let localData = media.localData {
            return localData
        }
        guard let reference = media.reference else {
            throw MediaDataError.missingReference
        }
        if let cached = await cache.cachedData(for: reference) {
            return cached
        }
        guard let appState, let accountRef = appState.activeAccountRef else {
            throw MediaDataError.missingAccount
        }
        let client = try appState.currentMarmotClient()
        return try await inFlight.data(
            for: MediaDownloadInFlightKey(reference: reference)
        ) {
            // Row references already carry the real source_epoch, so the reference
            // is directly downloadable — no listMedia round-trip to recover it.
            let result = try await self.downloadMedia(client, accountRef, groupIdHex, reference)
            await self.cache.store(result.plaintext, for: reference)
            return result.plaintext
        }
    }

    enum MediaDataError: LocalizedError {
        case missingReference
        case missingAccount

        var errorDescription: String? {
            switch self {
            case .missingReference:
                return L10n.string("This attachment is not ready yet.")
            case .missingAccount:
                return L10n.string("No active account.")
            }
        }
    }
}
