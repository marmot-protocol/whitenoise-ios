import MarmotKit

nonisolated struct AccountSetupRecoveryPresentation {
    struct ChildFailure: Equatable {
        enum Source { case relays, discovery }
        let source: Source
        let message: String
        let revision: UInt64
    }

    private(set) var snapshot: OnboardingSnapshotFfi
    private(set) var childFailure: ChildFailure?

    mutating func reportChildFailure(source: ChildFailure.Source, message: String, revision: UInt64) {
        childFailure = ChildFailure(source: source, message: message, revision: revision)
    }

    mutating func clearChildFailure() { childFailure = nil }

    // Keep the last reviewed content visible while its sheet dismisses.
    mutating func update(_ next: OnboardingSnapshotFfi, step: OnboardingStepFfi, operationError: String? = nil) -> Bool {
        if let status = next.steps.first(where: { $0.step == step })?.status,
           status == .passed || status == .skipped {
            return true
        }
        // The snapshot that caused a child failure must not erase that failure.
        if operationError == nil, let childFailure, next.revision > childFailure.revision {
            self.childFailure = nil
        }
        snapshot = next
        return false
    }
}
