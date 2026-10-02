import Foundation
import MarmotKit

extension MarmotClient {
    func attachmentPreview(accountRef: String, groupID: String) async throws -> AttachmentPageFfi {
        let result = try await marmot.attachmentHistoryPage(accountRef: accountRef,
            groupIdHex: groupID, limit: 100, cursor: nil)
        guard case .page(let page) = result else { throw AttachmentReadError.stale }
        return page
    }

    /// Every chunk revalidates the opaque reference against current visibility.
    func attachmentData(accountRef: String, groupID: String,
                        target: AttachmentLocalTargetFfi) async throws -> Data? {
        let assets = try await marmot.attachmentLocalAssets(accountRef: accountRef,
            groupIdHex: groupID, targets: [target])
        guard let asset = assets.first, let reference = asset.reference else { return nil }
        guard asset.byteCount <= 512 * 1024 * 1024 else { throw AttachmentReadError.tooLarge }
        return try await RetainedAttachmentReader.read(byteCount: asset.byteCount) { offset, limit in
            try await self.marmot.readAttachmentAsset(accountRef: accountRef,
                reference: reference, offset: offset, limit: limit)
        }
    }
}

nonisolated enum AttachmentReadError: Error {
    case stale
    case tooLarge
    case unavailable
}

/// Why a host load asks MDK for an attachment that has no retained bytes yet.
nonisolated enum AttachmentDemand: Hashable, Sendable {
    /// Visibility or policy prefetch. Never escalates to explicit work.
    case automatic
    /// An ordinary tap. Joins or promotes the current source without resetting its
    /// retry budget, backoff or deadline, and never re-arms failed, cancelled or removed work.
    case explicit
    /// The deliberate Retry offered after a failure. Re-arms terminal work.
    case retry

    /// A tap on an attachment that is showing its failure/Retry state is the deliberate Retry.
    static func userTap(afterFailure: Bool) -> AttachmentDemand {
        afterFailure ? .retry : .explicit
    }

    var isUserInitiated: Bool { self != .automatic }

    /// Only a failed user-initiated load shows the Retry state. An automatic failure leaves the
    /// next tap an ordinary explicit request, so it can surface a terminal source without re-arming it.
    var failureOffersRetry: Bool { isUserInitiated }

    /// Records the demand with MDK and returns whether transfer state is worth awaiting.
    /// A returned reference is intent, not readiness.
    func record(accountRef: String, groupID: String, target: AttachmentLocalTargetFfi,
                with requester: some AttachmentDemandRequesting) async throws -> Bool {
        switch self {
        case .automatic:
            let request = try await requester.requestAutomaticAttachment(accountRef: accountRef,
                groupIdHex: groupID, target: target)
            return AttachmentAcquisitionPresentation.canAwait(request.status.state)
        case .explicit:
            return try await requester.requestExplicitAttachment(accountRef: accountRef,
                groupIdHex: groupID, target: target) != nil
        case .retry:
            return try await requester.downloadAttachmentAgain(accountRef: accountRef,
                groupIdHex: groupID, target: target) != nil
        }
    }
}

/// The MDK attachment-demand calls, narrowed so demand routing can be tested without a runtime.
nonisolated protocol AttachmentDemandRequesting: Sendable {
    func requestAutomaticAttachment(accountRef: String, groupIdHex: String,
                                    target: AttachmentLocalTargetFfi) async throws -> AutomaticAttachmentRequestFfi
    func requestExplicitAttachment(accountRef: String, groupIdHex: String,
                                   target: AttachmentLocalTargetFfi) async throws -> String?
    func downloadAttachmentAgain(accountRef: String, groupIdHex: String,
                                 target: AttachmentLocalTargetFfi) async throws -> String?
}

extension Marmot: AttachmentDemandRequesting {}

extension MarmotClient {
    /// `onLocalHit` receives the elapsed milliseconds of a successful retained-byte read.
    func acquireAttachmentData(accountRef: String, groupID: String, target: AttachmentLocalTargetFfi,
                               demand: AttachmentDemand,
                               onLocalHit: (@Sendable (UInt64) -> Void)? = nil) async throws -> Data? {
        let localReadStartedAt = ContinuousClock.now
        if let data = try await attachmentData(accountRef: accountRef, groupID: groupID, target: target) {
            onLocalHit?(ProductAnalyticsRecorder.elapsedMilliseconds(from: localReadStartedAt, to: .now))
            return data
        }
        guard try await demand.record(accountRef: accountRef, groupID: groupID, target: target, with: marmot) else {
            throw AttachmentReadError.unavailable
        }
        let subscription = try await marmot.subscribeAttachmentTransfers(accountRef: accountRef,
            groupIdHex: groupID, targets: [target])
        return try await withTaskCancellationHandler {
            defer { subscription.cancel() }
            while let snapshot = try await subscription.next() {
                try Task.checkCancellation()
                guard let current = snapshot.items.first else { throw AttachmentReadError.unavailable }
                switch current.state {
                case .ready:
                    guard let data = try await attachmentData(accountRef: accountRef, groupID: groupID, target: target)
                    else { throw AttachmentReadError.stale }
                    return data
                case .unavailable, .cancelled, .removed, .failed, .policyBlocked, .paused,
                     .previouslyAcquiredUnavailable, .completedUnretained, .retryExhausted, .notRequested:
                    throw AttachmentReadError.unavailable
                default: break
                }
            }
            throw AttachmentReadError.unavailable
        } onCancel: {
            subscription.cancel()
        }
    }
}

nonisolated enum RetainedAttachmentReader {
    static func read(byteCount: UInt64,
                     chunk: (UInt64, UInt32) async throws -> AttachmentLocalBytesFfi) async throws -> Data {
        guard byteCount <= 512 * 1024 * 1024 else { throw AttachmentReadError.tooLarge }
        var data = Data()
        while true {
            try Task.checkCancellation()
            let next = try await chunk(UInt64(data.count), 1024 * 1024)
            guard next.available else { throw AttachmentReadError.stale }
            if next.bytes.isEmpty {
                guard UInt64(data.count) == byteCount else { throw AttachmentReadError.stale }
                return data
            }
            guard UInt64(data.count) + UInt64(next.bytes.count) <= byteCount else { throw AttachmentReadError.stale }
            data.append(next.bytes)
        }
    }
}

extension MarmotClient {
    /// Reply previews omit the original source event ID. Resolve their original slot locally.
    func resolveAttachmentTarget(accountRef: String, groupID: String,
                                 hint: AttachmentSourceHint) async throws -> AttachmentLocalTargetFfi {
        var cursor: AttachmentHistoryCursor?
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        repeat {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw AttachmentReadError.unavailable }
            let result = try await marmot.attachmentHistoryPage(accountRef: accountRef,
                groupIdHex: groupID, limit: 100, cursor: cursor)
            guard case .page(let page) = result else { throw AttachmentReadError.stale }
            for entry in page.entries where entry.messageIdHex == hint.messageID {
                if case .accepted(let index, _) = entry.attachment, index == hint.slot {
                    return AttachmentLocalTargetFfi(messageIdHex: entry.messageIdHex,
                        sourceMessageIdHex: entry.sourceMessageIdHex, attachmentIndex: index)
                }
            }
            cursor = page.hasMore ? page.nextCursor : nil
        } while cursor != nil
        throw AttachmentReadError.unavailable
    }
}

nonisolated enum AttachmentAcquisitionPresentation {
    static func canAwait(_ state: AttachmentTransferStateFfi) -> Bool {
        switch state {
        case .queued, .downloading, .verifyingCiphertext, .decrypting, .verifyingPlaintext,
             .ready, .retryScheduled: true
        case .unavailable, .notRequested, .paused, .failed, .policyBlocked, .cancelled, .removed,
             .previouslyAcquiredUnavailable, .completedUnretained, .retryExhausted: false
        }
    }
}
