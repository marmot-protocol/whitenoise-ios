import MarmotKit

nonisolated struct AccountSetupRecoveryPresentation {
    struct ChildFailure: Equatable {
        enum Source { case relays, discovery }
        let source: Source
        let failure: AccountSetupFailure
        let revision: UInt64
    }

    private(set) var snapshot: OnboardingSnapshotFfi
    private(set) var childFailure: ChildFailure?

    mutating func reportChildFailure(source: ChildFailure.Source, failure: AccountSetupFailure, revision: UInt64) {
        childFailure = ChildFailure(source: source, failure: failure, revision: revision)
    }

    mutating func clearChildFailure() { childFailure = nil }

    // Keep the last reviewed content visible while its sheet dismisses.
    mutating func update(_ next: OnboardingSnapshotFfi, step: OnboardingStepFfi, operationFailure: AccountSetupFailure? = nil) -> Bool {
        if let status = next.steps.first(where: { $0.step == step })?.status,
           status == .passed || status == .skipped {
            return true
        }
        // The snapshot that caused a child failure must not erase that failure.
        if operationFailure == nil, let childFailure, next.revision > childFailure.revision {
            self.childFailure = nil
        }
        snapshot = next
        return false
    }
}
