import Foundation
import MarmotKit
import os
import Synchronization

/// MDK's handoff release, narrowed so release retries can be tested without a runtime.
nonisolated protocol AttachmentHandoffReleasing: Sendable {
    func releaseAttachmentHandoff(lease: String) async throws
}

extension Marmot: AttachmentHandoffReleasing {}

/// Releases through whichever runtime is open when the release runs. Leases are
/// process-wide, but a background suspend closes the runtime that opened one.
nonisolated struct LiveRuntimeHandoffReleaser: AttachmentHandoffReleasing {
    /// No open runtime yet, as while the app is suspended; a later attempt finds one.
    struct Unavailable: Error {}

    let live: @Sendable () async -> (any AttachmentHandoffReleasing)?

    func releaseAttachmentHandoff(lease: String) async throws {
        guard let runtime = await live() else { throw Unavailable() }
        try await runtime.releaseAttachmentHandoff(lease: lease)
    }
}

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

    /// MDK writes the copy owner-only under the default Data Protection class, which
    /// stays readable once the device locks. Raise it to complete before an OS surface
    /// sees `url`; a copy that cannot be protected is released instead of shared.
    func protect() throws {
        do {
            let files = FileManager.default
            try files.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
            let applied = try files.attributesOfItem(atPath: url.path)[.protectionKey] as? FileProtectionType
            guard Self.isComplete(applied) else { throw AttachmentHandoffFailure.unprotected }
        } catch {
            release()
            throw AttachmentHandoffFailure.unprotected
        }
    }

    /// The simulator ignores Data Protection: setting a class is a no-op and none is reported.
    static let dataProtectionEnforced: Bool = {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }()

    static func isComplete(_ applied: FileProtectionType?, enforced: Bool = dataProtectionEnforced) -> Bool {
        applied == .complete || (!enforced && applied == nil)
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
        /// Still not released after every attempt; MDK wipes it on the next process start.
        case abandoned
    }

    static let maxAttempts = 10

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.ipf.whitenoise",
        category: "attachment-handoff"
    )

    /// MDK keeps a copy it could not delete leased (`Io`). A runtime that closed under
    /// the call, or none open yet, is retried against the next open runtime.
    static func isRetryable(_ error: Error) -> Bool {
        if case MarmotKitError.Io = error { return true }
        if case MarmotKitError.StorageClosed = error { return true }
        return error is LiveRuntimeHandoffReleaser.Unavailable
    }

    /// Doubles from 250 ms up to 30 s, about 90 s of foreground time in all, long
    /// enough for a resumed app to reopen its runtime.
    static func retryDelay(afterAttempt attempt: Int) -> Duration {
        min(.milliseconds(250 * (1 << min(max(attempt - 1, 0), 7))), .seconds(30))
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
        log.error("Attachment handoff copy still not released after \(maxAttempts, privacy: .public) attempts")
        return .abandoned
    }
}

/// Why a document could not be handed to the share sheet.
nonisolated enum AttachmentHandoffFailure: LocalizedError, Equatable {
    /// MDK holds no local copy, even after the tap's download settled.
    case notHeldLocally
    /// No room for the plaintext copy beyond MDK's disk reserve.
    case storageFull
    /// The copy could not be given complete file protection, so it was released.
    case unprotected

    var errorDescription: String? {
        switch self {
        case .notHeldLocally: L10n.string("This attachment is not ready yet.")
        case .storageFull: L10n.string("This device is out of storage. Free up some space and try again.")
        case .unprotected: L10n.string("Please try again.")
        }
    }
}

/// Where a shared document's file comes from. The original slot wins whenever the row
/// has one, even while the host still holds this device's own send in memory.
nonisolated enum AttachmentHandoffSource: Equatable {
    case target(AttachmentLocalTargetFfi)
    case hint(AttachmentSourceHint)
    /// No slot: an unsent draft, whose bytes only the host has.
    case none

    init(_ media: MessageMediaAttachment) {
        if let target = media.localTarget {
            self = .target(target)
        } else if let hint = media.sourceHint {
            self = .hint(hint)
        } else {
            self = .none
        }
    }
}

nonisolated enum AttachmentHandoffOpening {
    /// Opens from retained bytes first so a held document never passes through app
    /// memory. A miss returns nil when the host still has the bytes (this device's
    /// own send), and otherwise waits for the tap's download before one more attempt.
    static func open<Handoff>(
        handoff: () async throws -> Handoff?,
        hostHasBytes: Bool,
        acquire: () async throws -> Void
    ) async throws -> Handoff? {
        if let opened = try await handoff() { return opened }
        if hostHasBytes { return nil }
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

/// A file for the share sheet: MDK's leased copy, or the host's own export of bytes
/// MDK has no slot for or does not hold (an outgoing draft or send).
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
