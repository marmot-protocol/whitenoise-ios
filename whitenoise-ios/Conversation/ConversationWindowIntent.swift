import MarmotKit

/// Pixel offsets belong to SwiftUI; these intents change MDK's retained window.
nonisolated enum ConversationViewportIntent: Equatable {
    case followingLatest
    case history(String?)
}

/// Whether a "follow the live tail" request still needs a `.latest` window
/// command, or the window is already pinned there.
///
/// `returnToLatest` runs on the same handle the window subscription delivers
/// through, so a redundant one competes with the update that carries a
/// just-staged outgoing row (reproduced in MDK testing as a delayed pending
/// row when Send immediately follows a follow-latest command). Skipping it when
/// nothing would change is both cheaper and the fix on this side.
nonisolated enum ConversationLatestIntent {
    static func needsLatestCommand(
        hasWindow: Bool,
        intent: ConversationViewportIntent,
        hasMoreAfter: Bool,
        pendingAnchorIntent: String?,
        navigationFailed: Bool
    ) -> Bool {
        // No window yet: the intent still has to be recorded and issued.
        guard hasWindow else { return true }
        guard intent == .followingLatest else { return true }
        // Newer messages outside the loaded window, an anchor still waiting to
        // run, or a failed latest/jump all mean "not actually at the tail".
        return hasMoreAfter || pendingAnchorIntent != nil || navigationFailed
    }
}

enum ConversationWindowCommand: Equatable {
    case anchor(String)
    case latest
    case jump(String)
    case page(ConversationPageDirectionFfi)

    func execute(on window: ConversationWindowSubscription, revision: ConversationWindowRevisionFfi) async throws -> ConversationWindowSnapshotFfi {
        switch self {
        case .anchor(let id): return try await window.setVisibleAnchor(revision: revision, messageIdHex: id, timeoutMs: 0)
        case .latest: return try await window.returnToLatest(revision: revision, timeoutMs: 0)
        case .jump(let id): return try await window.jumpToMessage(revision: revision, messageIdHex: id, timeoutMs: 0)
        case .page(let direction): return try await window.page(revision: revision, direction: direction, count: 50, timeoutMs: 0)
        }
    }
}

/// A timeout/readiness error may follow admission; only Stale proves safe replay.
enum ConversationCommandResolution<Value> {
    case applied(Value)
    case rejected(any Error)
    case awaitingProjection(any Error)
    case superseded
}

@MainActor
enum ConversationCommandRunner {
    static func run<Value>(
        isCurrent: () -> Bool,
        revision: () -> ConversationWindowRevisionFfi?,
        waitForUpdate: (ConversationWindowRevisionFfi) async -> Void,
        execute: (ConversationWindowRevisionFfi) async throws -> Value
    ) async -> ConversationCommandResolution<Value> {
        for attempt in 0..<3 {
            guard !Task.isCancelled, isCurrent(), let current = revision() else { return .superseded }
            do {
                let result = try await execute(current)
                guard !Task.isCancelled, isCurrent() else { return .superseded }
                return .applied(result)
            } catch is CancellationError {
                return .superseded
            } catch MarmotKitError.ConversationWindowStale {
                if attempt == 2 { return .rejected(MarmotKitError.ConversationWindowStale) }
                await waitForUpdate(current)
            } catch MarmotKitError.ConversationWindowTimedOut {
                return .awaitingProjection(MarmotKitError.ConversationWindowTimedOut)
            } catch MarmotKitError.ConversationWindowNotReady {
                return .awaitingProjection(MarmotKitError.ConversationWindowNotReady)
            } catch {
                return .rejected(error)
            }
        }
        return .rejected(MarmotKitError.ConversationWindowStale)
    }
}

/// A page may finish after its call times out. Do not admit another page until
/// the single receiver has installed a later revision from the same handle.
struct ConversationPageAdmission {
    private(set) var unresolvedRevision: ConversationWindowRevisionFfi?

    mutating func awaitCompletion(of attempted: ConversationWindowRevisionFfi, installed: ConversationWindowRevisionFfi?) {
        if let installed, installed.generation == attempted.generation, installed.sequence > attempted.sequence { return }
        unresolvedRevision = attempted
    }

    mutating func observe(_ revision: ConversationWindowRevisionFfi) {
        guard let pending = unresolvedRevision, pending.generation == revision.generation,
              revision.sequence > pending.sequence else { return }
        unresolvedRevision = nil
    }
}
