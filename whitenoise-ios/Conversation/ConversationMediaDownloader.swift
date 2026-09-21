import Foundation
import Synchronization
import CryptoKit
import MarmotKit

/// Dedup key for an in-flight media download: a content-addressed media
/// reference normalized to lowercase hex.
struct MediaDownloadInFlightKey: Hashable {
    let version: EncryptedMediaVersionFfi
    let plaintextSha256: String
    let ciphertextSha256: String
    let nonceHex: String
    let target: AttachmentLocalTargetFfi?
    let explicit: Bool
    let sourceHint: AttachmentSourceHint?
    let scope: String

    init(reference: MediaAttachmentReferenceFfi, target: AttachmentLocalTargetFfi? = nil, explicit: Bool = false, sourceHint: AttachmentSourceHint? = nil, scope: String = "") {
        self.sourceHint = sourceHint
        self.scope = scope
        self.target = target
        self.explicit = explicit
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
    private struct Entry {
        let id: UUID
        let task: Task<Data, Error>
    }

    private var tasks: [MediaDownloadInFlightKey: Entry] = [:]

    func data(
        for key: MediaDownloadInFlightKey,
        operation: @escaping @MainActor () async throws -> Data
    ) async throws -> Data {
        if let entry = tasks[key] {
            return try await entry.task.value
        }
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            defer { self?.clearTask(for: key, id: id) }
            return try await operation()
        }
        tasks[key] = Entry(id: id, task: task)
        return try await task.value
    }

    func cancelAndDrain() async {
        let pending = Array(tasks.values)
        pending.forEach { $0.task.cancel() }
        for entry in pending { _ = try? await entry.task.value }
    }

    private func clearTask(for key: MediaDownloadInFlightKey, id: UUID) {
        guard tasks[key]?.id == id else {
            return
        }
        tasks[key] = nil
    }
}

nonisolated enum MediaPlaintextHash {
    static func matches(_ data: Data, expectedSha256: String) async -> Bool {
        await Task.detached(priority: .utility) {
            sha256Hex(of: data) == expectedSha256.lowercased()
        }.value
    }

    private static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

@MainActor
protocol ConversationMediaCacheAccessing {
    var producerGeneration: Int { get }
    func cachedData(for reference: MediaAttachmentReferenceFfi) async -> Data?
    func store(_ data: Data, for reference: MediaAttachmentReferenceFfi, producerGeneration: Int?) async
}

struct DefaultConversationMediaCache: ConversationMediaCacheAccessing {
    var producerGeneration: Int { MessageMediaCache.currentProducerEpoch() }

    func cachedData(for reference: MediaAttachmentReferenceFfi) async -> Data? {
        await MessageMediaCache.cachedData(for: reference)
    }

    func store(_ data: Data, for reference: MediaAttachmentReferenceFfi, producerGeneration: Int?) async {
        await MessageMediaCache.store(data, for: reference, producerGeneration: producerGeneration)
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
    private let locatorResolver: HostResolutionGuard.Resolver

    init(
        cache: ConversationMediaCacheAccessing? = nil,
        locatorResolver: @escaping HostResolutionGuard.Resolver = HostResolutionGuard.systemResolver,
        downloadMedia: @escaping DownloadMedia = { client, accountRef, groupIdHex, reference in
            try await client.downloadMedia(
                accountRef: accountRef,
                groupIdHex: groupIdHex,
                reference: reference
            )
        }
    ) {
        self.cache = cache ?? DefaultConversationMediaCache()
        self.locatorResolver = locatorResolver
        self.downloadMedia = downloadMedia
    }

    private var isStopped = false

    func stopAndDrain() async {
        isStopped = true
        await inFlight.cancelAndDrain()
    }

    func resume() { isStopped = false }

    func data(for media: MessageMediaAttachment, groupIdHex: String, appState: AppState?) async throws -> Data {
        guard !isStopped else { throw CancellationError() }
        if let localData = media.localData {
            return localData
        }
        guard let reference = media.reference else {
            throw MediaDataError.missingReference
        }
        guard EncryptedMediaLocatorValidation.isStaticallySafe(reference.locators) else {
            throw MediaDataError.unsafeLocator
        }
        return try await inFlight.data(
            for: MediaDownloadInFlightKey(reference: reference, target: media.localTarget, explicit: media.downloadExplicitly,
                sourceHint: media.sourceHint, scope: "\(appState?.activeAccountRef ?? "")/\(appState?.runtimeGeneration ?? 0)/\(groupIdHex)")
        ) {
            var target = media.localTarget
            if target == nil, let hint = media.sourceHint,
               let appState, let account = appState.activeAccountRef {
                let client = try appState.currentMarmotClient()
                target = try await client.resolveAttachmentTarget(accountRef: account, groupID: groupIdHex, hint: hint)
            }
            if let target {
                guard let appState, let account = appState.activeAccountRef else { throw MediaDataError.missingAccount }
                let client = try appState.currentMarmotClient()
                if let data = try await client.acquireAttachmentData(accountRef: account, groupID: groupIdHex,
                    target: target, explicit: media.downloadExplicitly) {
                    try Task.checkCancellation()
                    guard !self.isStopped, appState.activeAccountRef == account, appState.client === client else {
                        throw CancellationError()
                    }
                    guard await MediaPlaintextHash.matches(data, expectedSha256: reference.plaintextSha256) else {
                        throw MediaDataError.plaintextHashMismatch
                    }
                    return data
                }
            }
            // A cache miss never grants new automatic network work. Source-scoped
            // MDK reads above own expiry, removal and acquisition history.
            guard media.downloadExplicitly else { throw AttachmentReadError.unavailable }
            let producerEpoch = self.cache.producerGeneration
            if let cached = await self.cache.cachedData(for: reference),
               await MediaPlaintextHash.matches(cached, expectedSha256: reference.plaintextSha256) {
                try Task.checkCancellation()
                guard !self.isStopped, self.cache.producerGeneration == producerEpoch else { throw CancellationError() }
                return cached
            }
            guard let appState, let accountRef = appState.activeAccountRef else {
                throw MediaDataError.missingAccount
            }
            let locatorResolver = self.locatorResolver
            let locatorResolutionIsSafe = await Task.detached(priority: .utility) {
                EncryptedMediaLocatorValidation.resolvesOnlyToPublicAddresses(
                    reference.locators,
                    resolver: locatorResolver
                )
            }.value
            guard locatorResolutionIsSafe else {
                throw MediaDataError.unsafeLocator
            }
            let client = try appState.currentMarmotClient()
            // Row references already carry the real source_epoch, so the reference
            // is directly downloadable — no listMedia round-trip to recover it.
            let result = try await self.downloadMedia(client, accountRef, groupIdHex, reference)
            guard await MediaPlaintextHash.matches(
                result.plaintext,
                expectedSha256: reference.plaintextSha256
            ) else {
                throw MediaDataError.plaintextHashMismatch
            }
            try Task.checkCancellation()
            guard !self.isStopped else { throw CancellationError() }
            guard appState.activeAccountRef == accountRef, appState.client === client else { throw CancellationError() }
            if let target {
                let state = try await client.marmot.attachmentTransferSnapshot(accountRef: accountRef,
                    groupIdHex: groupIdHex, targets: [target]).items.first?.state
                guard let state, ![.unavailable, .removed, .cancelled].contains(state) else {
                    throw AttachmentReadError.stale
                }
            }
            await self.cache.store(result.plaintext, for: reference, producerGeneration: producerEpoch)
            guard self.cache.producerGeneration == producerEpoch else { throw CancellationError() }
            return result.plaintext
        }
    }

    enum MediaDataError: LocalizedError, Equatable {
        case missingReference
        case missingAccount
        case unsafeLocator
        case plaintextHashMismatch

        var errorDescription: String? {
            switch self {
            case .missingReference:
                return L10n.string("This attachment is not ready yet.")
            case .missingAccount:
                return L10n.string("No active account.")
            case .unsafeLocator:
                return L10n.string("This attachment uses an unsafe download location.")
            case .plaintextHashMismatch:
                return L10n.string("Attachment verification failed.")
            }
        }
    }
}
