import Foundation
import MarmotKit

/// Owns the local account list and the active-account selection. A self-contained
/// observable data store: `activeAccountRef` persists to UserDefaults via its own
/// `didSet`, and `activeAccount` resolves purely from the list — so the store
/// needs no `AppState` back-reference. AppState performs the Marmot fetch that
/// refreshes `accounts` (client access is its domain) and orchestrates the
/// identity lifecycle (create / import / sign-out).
@MainActor
@Observable
final class AccountStore {
    static let activeAccountKey = "marmot.activeAccountRef"

    /// All accounts known to marmot-app, refreshed after every account-changing call.
    var accounts: [AccountSummaryFfi] = []

    /// The account whose chats / messages are currently displayed.
    /// `nil` only between bootstrap and onboarding completion. Restored from and
    /// persisted to UserDefaults so the selection survives relaunch.
    var activeAccountRef: String? = UserDefaults.standard.string(forKey: AccountStore.activeAccountKey) {
        didSet {
            if let ref = activeAccountRef {
                UserDefaults.standard.set(ref, forKey: Self.activeAccountKey)
            } else {
                // Clearing the ref (e.g. signing out of the only account) must
                // remove the persisted value, otherwise the next launch
                // resurrects the signed-out account from UserDefaults.
                UserDefaults.standard.removeObject(forKey: Self.activeAccountKey)
            }
        }
    }

    /// The active account summary resolved from the list, or nil.
    var activeAccount: AccountSummaryFfi? {
        guard let ref = activeAccountRef else { return nil }
        return accounts.first { $0.label == ref }
    }
}
