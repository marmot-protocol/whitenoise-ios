import Foundation
import MarmotKit

/// Accounts whose native-push preference an account exit turned off and must
/// turn back on if the exit does not finish. Persisted before the preference
/// is flipped, so a runtime that suspension already closed, or a process that
/// dies mid-exit, still leaves the restore for the next live runtime.
@MainActor
final class NativePushRestoreIntents {
    // Avoid the task-local isolated-deinit crash on iOS 26.2 and older.
    // https://github.com/swiftlang/swift/issues/88036
    nonisolated deinit {}

    nonisolated enum Action: Equatable {
        /// The profile is still signed in here: turn native push back on.
        case restore
        /// The exit finished after all (removed or signed out): forget it.
        case discard
        /// The account list could not be read: try again on a later pass.
        case wait
    }

    private static let key = "marmot.nativePushRestoreAfterAccountExit"
    private let defaults: UserDefaults
    private(set) var accountRefs: Set<String>

    init(defaults: UserDefaults) {
        self.defaults = defaults
        accountRefs = Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    func mark(_ accountRef: String) { accountRefs.insert(accountRef); save() }
    func clear(_ accountRef: String) { accountRefs.remove(accountRef); save() }
    func reset() { accountRefs.removeAll(); defaults.removeObject(forKey: Self.key) }
    private func save() { defaults.set(accountRefs.sorted(), forKey: Self.key) }

    nonisolated static func action(for accountRef: String, storedAccounts: [AccountSummaryFfi]?) -> Action {
        guard let storedAccounts else { return .wait }
        guard let account = storedAccounts.first(where: { $0.label == accountRef }), !account.signedOut else {
            return .discard
        }
        return .restore
    }
}
