import Foundation

/// Both single and bulk actions distinguish an accepted request from ended membership.
@MainActor
enum ChatLeaveOperation {
    struct Context: Equatable {
        let accountRef: String
        let runtimeGeneration: Int
    }

    struct State {
        var membershipEnded = false
        var leaveRequestPending = false
        var canLeave = false
        var requiresSelfDemotion = false
        var blockedMessage = ""

        var settledResult: Result? {
            if membershipEnded { return .left }
            return leaveRequestPending ? .pending : nil
        }
    }

    enum Result: Equatable {
        case left, pending, failed, cancelled
        case blocked(String)
    }

    static func perform(
        isCurrent: () -> Bool,
        readState: () async throws -> State,
        selfDemote: () async throws -> Void,
        leave: () async throws -> Void
    ) async -> Result {
        func canContinue() -> Bool { !Task.isCancelled && isCurrent() }
        guard canContinue() else { return .cancelled }
        do {
            let state = try await readState()
            guard canContinue() else { return .cancelled }
            if let result = state.settledResult { return result }
            guard state.canLeave else { return .blocked(state.blockedMessage) }
            if state.requiresSelfDemotion {
                try await selfDemote()
                guard canContinue() else { return .cancelled }
            }
            try await leave()
            guard canContinue() else { return .cancelled }
            // A successful SDK leave durably records local membership as left.
            return .left
        } catch {
            guard canContinue() else { return .cancelled }
            // Publishing can throw after recording a request. Read durable state
            // rather than interpreting the error itself as ended membership.
            let state = try? await readState()
            guard canContinue() else { return .cancelled }
            return state?.settledResult ?? .failed
        }
    }
}
