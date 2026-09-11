import Foundation

/// Prewarming is advisory; Create and Invite still fetch fresh KeyPackages.
@MainActor
final class MemberKeyPackagePrewarmer {
    private struct Request: Equatable {
        let accountRef: String?
        let runtimeGeneration: Int
        let memberRefs: [String]
    }

    private var request: Request?
    private var task: Task<Void, Never>?

    @discardableResult
    func schedule(
        memberRefs: [String],
        accountRef: String?,
        runtimeGeneration: Int,
        debounce: Duration = .milliseconds(250),
        prewarm: @escaping @MainActor ([String]) async -> Void
    ) -> Bool {
        guard !memberRefs.isEmpty else {
            cancel()
            return false
        }
        let next = Request(accountRef: accountRef, runtimeGeneration: runtimeGeneration,
                           memberRefs: Array(Set(memberRefs)).sorted())
        guard next != request else { return false }
        cancel()
        request = next
        task = Task { @MainActor in
            do {
                try await Task.sleep(for: debounce)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await prewarm(memberRefs)
        }
        return true
    }

    func cancel() {
        task?.cancel()
        task = nil
        request = nil
    }
}
