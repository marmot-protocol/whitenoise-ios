import Foundation
import MarmotKit
import os
import Synchronization

/// MDK's handoff release, narrowed so release retries can be tested without a runtime.
/// Leases are process-wide, so the instance that opened one can release it after a
/// runtime suspend or rebuild.
nonisolated protocol AttachmentHandoffReleasing: Sendable {
    func releaseAttachmentHandoff(lease: String) async throws
}

extension Marmot: AttachmentHandoffReleasing {}

/// A private plaintext copy MDK lent for an OS surface such as the share sheet.
/// Release it when the surface completes or dismisses. Release is idempotent, and
/// dropping the last reference releases as a backstop.
nonisolated final class AttachmentHandoffLease: Sendable {
    let url: URL
    private let lease: String
    private let releaser: any AttachmentHandoffReleasing
    private let isReleased = Mutex(false)

    init(lease: String, path: String, releaser: any AttachmentHandoffReleasing) {
        url = URL(fileURLWithPath: path, isDirectory: false)
        self.lease = lease
        self.releaser = releaser
    }

    convenience init(_ handoff: AttachmentHandoffFfi, releaser: any AttachmentHandoffReleasing) {
        self.init(lease: handoff.lease, path: handoff.path, releaser: releaser)
    }

    /// Deletes the copy; never use `url` afterwards. Returns nil when already released.
    @discardableResult
    func release() -> Task<AttachmentHandoffRelease.Outcome, Never>? {
        let isFirst = isReleased.withLock { released in
            defer { released = true }
            return !released
        }
        guard isFirst else { return nil }
        let lease = lease, releaser = releaser
        // Nobody cancels this task: the copy holds plaintext until MDK deletes it.
        return Task.detached(priority: .utility) {
            await AttachmentHandoffRelease.run(lease: lease, using: releaser)
        }
    }

    deinit { release() }
}

nonisolated enum AttachmentHandoffRelease {
    enum Outcome: Equatable, Sendable {
        case released
        /// A malformed lease, which no retry fixes.
        case rejected
        /// Still undeletable after every attempt; MDK wipes it on the next process start.
        case abandoned
    }

    static let maxAttempts = 5

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.ipf.whitenoise",
        category: "attachment-handoff"
    )

    /// MDK keeps a copy it could not delete leased and asks for another release.
    static func isRetryable(_ error: Error) -> Bool {
        if case MarmotKitError.Io = error { return true }
        return false
    }

    static func retryDelay(afterAttempt attempt: Int) -> Duration {
        .milliseconds(250 * (1 << min(max(attempt - 1, 0), 4)))
    }

    static func run(
        lease: String,
        using releaser: some AttachmentHandoffReleasing,
        sleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) async -> Outcome {
        for attempt in 1...maxAttempts {
            do {
                try await releaser.releaseAttachmentHandoff(lease: lease)
                return .released
            } catch {
                guard isRetryable(error) else {
                    log.error("Attachment handoff release rejected: \(String(describing: type(of: error)), privacy: .public)")
                    return .rejected
                }
                if attempt < maxAttempts { await sleep(retryDelay(afterAttempt: attempt)) }
            }
        }
        log.error("Attachment handoff copy still undeletable after \(maxAttempts, privacy: .public) attempts")
        return .abandoned
    }
}

/// Why a document could not be handed to the share sheet.
nonisolated enum AttachmentHandoffFailure: LocalizedError, Equatable {
    /// MDK holds no local copy, even after the tap's download settled.
    case notHeldLocally
    /// No room for the plaintext copy beyond MDK's disk reserve.
    case storageFull

    var errorDescription: String? {
        switch self {
        case .notHeldLocally: L10n.string("This attachment is not ready yet.")
        case .storageFull: L10n.string("This device is out of storage. Free up some space and try again.")
        }
    }
}

nonisolated enum AttachmentHandoffOpening {
    /// Opens from retained bytes first so a held document never passes through app
    /// memory; only a miss waits for the tap's download before one more attempt.
    static func open<Handoff>(
        handoff: () async throws -> Handoff?,
        acquire: () async throws -> Void
    ) async throws -> Handoff {
        if let opened = try await handoff() { return opened }
        try await acquire()
        guard let opened = try await handoff() else { throw AttachmentHandoffFailure.notHeldLocally }
        return opened
    }

    /// A copy cancelled through its control surfaces as an invalid-media error.
    static func failure(for error: Error, controlCancelled: Bool) -> Error {
        if controlCancelled { return CancellationError() }
        if case MarmotKitError.StorageFull = error { return AttachmentHandoffFailure.storageFull }
        return error
    }

    /// Awaits `call` in a task nobody cancels: cancelling a task awaiting
    /// `openAttachmentHandoff` can drop a finished lease, so a cancelled caller
    /// cancels through `control` instead.
    static func shielded<T: Sendable>(
        cancel: @escaping @Sendable () -> Void,
        _ call: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let task = Task.detached(priority: .userInitiated) { try await call() }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            cancel()
        }
    }
}

/// A file for the share sheet: MDK's leased copy, or the host's own export of
/// bytes MDK has no source slot for (an outgoing draft).
struct AttachmentShareFile: Identifiable {
    let id = UUID()
    let url: URL
    let lease: AttachmentHandoffLease?

    init(lease: AttachmentHandoffLease) {
        url = lease.url
        self.lease = lease
    }

    init(hostURL: URL) {
        url = hostURL
        lease = nil
    }

    /// Call when the share sheet completes or dismisses.
    func finish() { lease?.release() }
}
