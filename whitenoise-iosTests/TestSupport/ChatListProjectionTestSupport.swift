@testable import whitenoise_ios
import MarmotKit
import Synchronization
import Testing

/// Stands in for Marmot behind a `ChatsListViewModel`'s windowed list and row
/// refresh. Tests replace either read at any point; a read the test didn't set
/// records an issue.
@MainActor
final class ChatListProjectionDouble: ChatListProjectionClient {
    var presentedRow: @MainActor (_ accountRef: String, _ groupIdHex: String) async throws -> PresentedChatRowFfi? = { _, _ in
        Issue.record("unexpected presented row read")
        return nil
    }

    var openWindow: @MainActor (_ accountRef: String, _ view: ChatListViewFfi) async throws -> any ChatListWindowFeed = { _, _ in
        Issue.record("unexpected chat-list window open")
        throw CancellationError()
    }

    func presentedChatListRow(accountRef: String, groupIdHex: String) async throws -> PresentedChatRowFfi? {
        try await presentedRow(accountRef, groupIdHex)
    }

    func openChatListWindowFeed(accountRef: String, view: ChatListViewFfi) async throws -> any ChatListWindowFeed {
        try await openWindow(accountRef, view)
    }
}

/// An open chat-list window whose updates and command results the test supplies.
final class ChatListWindowFeedDouble: ChatListWindowFeed {
    private struct State {
        var updates: [ChatListWindowSnapshotFfi] = []
        var reader: CheckedContinuation<ChatListWindowSnapshotFfi?, any Error>?
        var commandResults: [ChatListWindowSnapshotFfi] = []
    }

    private let initial: ChatListWindowSnapshotFfi
    private let state = Mutex(State())

    init(initial: ChatListWindowSnapshotFfi) {
        self.initial = initial
    }

    /// Delivers `update` to the view model's update loop.
    func send(_ update: ChatListWindowSnapshotFfi) {
        let reader = state.withLock { state in
            guard let reader = state.reader else {
                state.updates.append(update)
                return nil as CheckedContinuation<ChatListWindowSnapshotFfi?, any Error>?
            }
            state.reader = nil
            return reader
        }
        reader?.resume(returning: update)
    }

    /// Makes the next window command (anchor, page or return to top) return `result`.
    func enqueueCommandResult(_ result: ChatListWindowSnapshotFfi) {
        state.withLock { $0.commandResults.append(result) }
    }

    /// Command results queued with `enqueueCommandResult` that no command has used yet.
    var unusedCommandResults: Int {
        state.withLock { $0.commandResults.count }
    }

    func snapshot() -> ChatListWindowSnapshotFfi? {
        initial
    }

    func nextCancellable() async throws -> ChatListWindowSnapshotFfi? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let ready: Result<ChatListWindowSnapshotFfi?, any Error>? = state.withLock { state in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if !state.updates.isEmpty { return .success(state.updates.removeFirst()) }
                    state.reader = continuation
                    return nil
                }
                if let ready { continuation.resume(with: ready) }
            }
        } onCancel: {
            let reader = state.withLock { state in
                defer { state.reader = nil }
                return state.reader
            }
            reader?.resume(throwing: CancellationError())
        }
    }

    func setVisibleAnchor(sequence: UInt64, groupIdHex: String) async throws -> ChatListWindowSnapshotFfi {
        try nextCommandResult()
    }

    func page(sequence: UInt64, direction: ChatListPageDirectionFfi, count: UInt32) async throws
        -> ChatListWindowSnapshotFfi
    {
        try nextCommandResult()
    }

    func returnToTop(sequence: UInt64) async throws -> ChatListWindowSnapshotFfi {
        try nextCommandResult()
    }

    private func nextCommandResult() throws -> ChatListWindowSnapshotFfi {
        guard let result = state.withLock({ $0.commandResults.isEmpty ? nil : $0.commandResults.removeFirst() }) else {
            Issue.record("unexpected chat-list window command")
            throw CancellationError()
        }
        return result
    }
}
