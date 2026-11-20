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
    let demand: AttachmentDemand
    let previewByteLimit: Int?
    let sourceHint: AttachmentSourceHint?
    let scope: String

    init(reference: MediaAttachmentReferenceFfi, target: AttachmentLocalTargetFfi? = nil, demand: AttachmentDemand = .automatic, sourceHint: AttachmentSourceHint? = nil, scope: String = "", previewByteLimit: Int? = nil) {
        self.previewByteLimit = previewByteLimit
        self.sourceHint = sourceHint
        self.scope = scope
        self.target = target
        self.demand = demand
        self.version = reference.version
        self.plaintextSha256 = reference.plaintextSha256.lowercased()
        self.ciphertextSha256 = reference.ciphertextSha256.lowercased()
        self.nonceHex = reference.nonceHex.lowercased()
    }
}

/// Coalesces concurrent downloads of the same media reference so duplicate
/// thumbnail/gallery requests share one decrypt/download task.
@MainActor
final class MediaDownloadInFlightStore<Value: Sendable> {
    private struct Entry {
        let id: UUID
        let task: Task<Value, Error>
    }

    private var tasks: [MediaDownloadInFlightKey: Entry] = [:]

    func value(
        for key: MediaDownloadInFlightKey,
        operation: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
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
        // Runs on the path of a visible attachment load, so it must not queue at utility.
        await Task.detached(priority: .userInitiated) {
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

    private let inFlight = MediaDownloadInFlightStore<Data>()
    private let attachmentSizes = MediaDownloadInFlightStore<Int?>()
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
    private var handoffControls: [ObjectIdentifier: MediaFileTransferControlFfi] = [:]

    func stopAndDrain() async {
        isStopped = true
        handoffControls.values.forEach { $0.cancel() }
        async let sizes: Void = attachmentSizes.cancelAndDrain()
        await inFlight.cancelAndDrain()
        await sizes
    }

    func resume() { isStopped = false }

    /// Reads the retained size without loading the file. A missing slot uses automatic acquisition.
    func automaticAttachmentByteCount(for media: MessageMediaAttachment, groupIdHex: String, appState: AppState?) async -> Int? {
        guard !isStopped, !Task.isCancelled else { return nil }
        if let data = media.localData { return data.count }
        guard let reference = media.reference, EncryptedMediaLocatorValidation.isStaticallySafe(reference.locators),
              let appState, let account = appState.activeAccountRef,
              let client = try? appState.currentMarmotClient() else { return nil }
        let generation = appState.runtimeGeneration
        let key = MediaDownloadInFlightKey(reference: reference, target: media.localTarget, sourceHint: media.sourceHint,
                                          scope: "\(account)/\(generation)/\(groupIdHex)")
        @MainActor func isCurrent() -> Bool {
            !Task.isCancelled && !self.isStopped && appState.activeAccountRef == account
                && appState.client === client && appState.runtimeGeneration == generation
        }
        let size = try? await attachmentSizes.value(for: key) {
            guard isCurrent() else { return nil }
            let target: AttachmentLocalTargetFfi
            if let original = media.localTarget { target = original }
            else if let hint = media.sourceHint {
                target = try await client.resolveAttachmentTarget(accountRef: account, groupID: groupIdHex, hint: hint)
            } else { return nil }
            @MainActor func retainedSize() async throws -> Int? {
                guard isCurrent() else { throw CancellationError() }
                let assets = try await client.marmot.attachmentLocalAssets(accountRef: account,
                    groupIdHex: groupIdHex, targets: [target])
                guard let asset = assets.first, asset.reference != nil else { return nil }
                return Int(exactly: asset.byteCount)
            }
            if let size = try await retainedSize() { return size }
            guard isCurrent() else { return nil }
            try await client.fetchAttachment(accountRef: account, groupID: groupIdHex, target: target, demand: .automatic)
            return try await retainedSize()
        }
        return isCurrent() ? size : nil
    }

    /// Has MDK fetch an attachment ahead of its row. The bytes are not read
    /// here: the row's own load reads and verifies them. Returns false when
    /// MDK could not be asked yet.
    func fetchAhead(_ media: MessageMediaAttachment, groupIdHex: String, appState: AppState?) async -> Bool {
        guard media.localData == nil, let reference = media.reference,
              EncryptedMediaLocatorValidation.isStaticallySafe(reference.locators),
              let target = media.localTarget else { return true }
        guard !isStopped, let appState, let account = appState.activeAccountRef,
              let client = try? appState.currentMarmotClient() else { return false }
        try? await client.fetchAttachment(accountRef: account, groupID: groupIdHex, target: target, demand: .automatic)
        return true
    }

    func data(for media: MessageMediaAttachment, groupIdHex: String, appState: AppState?) async throws -> Data {
        guard !isStopped else { throw CancellationError() }
        if let localData = media.localData {
            if let limit = media.previewByteLimit, localData.count > limit {
                throw AttachmentReadError.previewLimitExceeded(byteCount: localData.count)
            }
            return localData
        }
        guard let reference = media.reference else {
            throw MediaDataError.missingReference
        }
        guard EncryptedMediaLocatorValidation.isStaticallySafe(reference.locators) else {
            throw MediaDataError.unsafeLocator
        }
        return try await inFlight.value(
            for: MediaDownloadInFlightKey(reference: reference, target: media.localTarget, demand: media.demand,
                sourceHint: media.sourceHint, scope: "\(appState?.activeAccountRef ?? "")/\(appState?.runtimeGeneration ?? 0)/\(groupIdHex)",
                previewByteLimit: media.previewByteLimit)
        ) {
            // host_media_load: plaintext bytes from MDK, the host cache, or download.
            let recorder = appState?.productAnalytics
            let loadTiming = recorder?.beginTiming()
            let cacheTicket = recorder?.ticket()
            func recordCacheRead(_ milliseconds: UInt64) {
                recorder?.recordPerformance(.mediaCacheRead, milliseconds: milliseconds, ticket: cacheTicket)
            }
            var loadOutcome = HostPerformanceOutcomeFfi.failure
            defer { recorder?.recordStage(.mediaLoad, since: loadTiming, outcome: loadOutcome) }
            do {
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
                        target: target, demand: media.demand, previewByteLimit: media.previewByteLimit,
                        onLocalHit: { [recorder, cacheTicket] milliseconds in
                            recorder?.recordPerformance(.mediaCacheRead, milliseconds: milliseconds, ticket: cacheTicket)
                        }) {
                        try Task.checkCancellation()
                        guard !self.isStopped, appState.activeAccountRef == account, appState.client === client else {
                            throw CancellationError()
                        }
                        guard await MediaPlaintextHash.matches(data, expectedSha256: reference.plaintextSha256) else {
                            throw MediaDataError.plaintextHashMismatch
                        }
                        loadOutcome = .success
                        return data
                    }
                }
                // Without a retained slot there is no trusted length to bound a preview read.
                if media.previewByteLimit != nil { throw AttachmentReadError.previewLimitExceeded(byteCount: nil) }
                // A cache miss never grants new automatic network work. Source-scoped
                // MDK reads above own expiry, removal and acquisition history.
                guard media.demand.isUserInitiated else { throw AttachmentReadError.unavailable }
                let producerEpoch = self.cache.producerGeneration
                let cacheReadStartedAt = ContinuousClock.now
                if let cached = await self.cache.cachedData(for: reference),
                   await MediaPlaintextHash.matches(cached, expectedSha256: reference.plaintextSha256) {
                    recordCacheRead(ProductAnalyticsRecorder.elapsedMilliseconds(from: cacheReadStartedAt, to: .now))
                    try Task.checkCancellation()
                    guard !self.isStopped, self.cache.producerGeneration == producerEpoch else { throw CancellationError() }
                    loadOutcome = .success
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
                    guard let state, ![.unavailable, .removed, .cleanedBySetting, .cancelled].contains(state) else {
                        throw AttachmentReadError.stale
                    }
                }
                await self.cache.store(result.plaintext, for: reference, producerGeneration: producerEpoch)
                guard self.cache.producerGeneration == producerEpoch else { throw CancellationError() }
                loadOutcome = .success
                return result.plaintext
            } catch is CancellationError {
                loadOutcome = .cancelled
                throw CancellationError()
            } catch AttachmentReadError.unavailable {
                loadOutcome = .unavailable
                throw AttachmentReadError.unavailable
            } catch AttachmentReadError.previewLimitExceeded(let byteCount) {
                loadOutcome = .unavailable
                throw AttachmentReadError.previewLimitExceeded(byteCount: byteCount)
            } catch AttachmentReadError.storageBlocked {
                loadOutcome = .unavailable
                // Automatic loads stay quiet; a tap explains why its Retry needs free space.
                if media.demand.isUserInitiated {
                    appState?.present(.warning(
                        L10n.string("Not enough storage"),
                        message: L10n.string("Free up space on this device, then tap the attachment to try again.")
                    ))
                }
                throw AttachmentReadError.storageBlocked
            }
        }
    }

    /// MDK's leased plaintext copy of the item's original source slot, for the share
    /// sheet. Nil when MDK has no slot for it (an unsent draft) or does not hold this
    /// device's own send yet, so the caller exports the host's bytes. A slot MDK does
    /// not hold yet is otherwise acquired with the item's demand first; cancel only
    /// through `control`.
    func openHandoff(for media: MessageMediaAttachment, groupIdHex: String, appState: AppState?,
                     control: MediaFileTransferControlFfi) async throws -> AttachmentHandoffLease? {
        guard !isStopped else { throw CancellationError() }
        let source = AttachmentHandoffSource(media)
        guard source != .none else { return nil }
        let hostHasBytes = media.localData != nil
        guard let appState, let account = appState.activeAccountRef else { throw MediaDataError.missingAccount }
        let client = try appState.currentMarmotClient()
        let marmot = client.marmot
        let releaser = LiveRuntimeHandoffReleaser { @MainActor [weak appState] in
            guard let live = appState?.client?.marmot, !live.storageIsClosed() else { return nil }
            return live
        }
        let controlID = ObjectIdentifier(control)
        handoffControls[controlID] = control
        defer { handoffControls[controlID] = nil }
        do {
            let target: AttachmentLocalTargetFfi
            switch source {
            case .target(let slot):
                target = slot
            case .hint(let hint):
                do {
                    target = try await client.resolveAttachmentTarget(accountRef: account, groupID: groupIdHex, hint: hint)
                } catch AttachmentReadError.unavailable where hostHasBytes {
                    return nil
                }
            case .none:
                return nil
            }
            guard let lease = try await AttachmentHandoffOpening.open(
                handoff: {
                    try await AttachmentHandoffOpening.shielded(cancel: { control.cancel() }) {
                        () async throws -> AttachmentHandoffLease? in
                        guard let handoff = try await marmot.openAttachmentHandoff(accountRef: account,
                            groupIdHex: groupIdHex, target: target, control: control) else { return nil }
                        let lease = AttachmentHandoffLease(handoff, target: target, releaser: releaser)
                        try lease.protect()
                        return lease
                    }
                },
                hostHasBytes: hostHasBytes,
                acquire: { _ = try await self.data(for: media, groupIdHex: groupIdHex, appState: appState) }
            ) else { return nil }
            guard !Task.isCancelled, !isStopped, appState.activeAccountRef == account, appState.client === client else {
                lease.release()
                throw CancellationError()
            }
            return lease
        } catch {
            let failure = AttachmentHandoffOpening.failure(for: error, controlCancelled: control.isCancelled())
            if failure as? AttachmentHandoffFailure == .storageFull {
                appState.present(.warning(
                    L10n.string("Not enough storage"),
                    message: L10n.string("Free up space on this device, then tap the attachment to try again.")
                ))
            }
            throw failure
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
