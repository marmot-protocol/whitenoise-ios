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
    private static let profileSelectionKey = "marmot.chooseProfileAfterSignOut"
    private(set) var prefersProfileSelection: Bool
    private(set) var returnsToSettingsAfterSelection = false

    @ObservationIgnored private let defaults: UserDefaults

    /// All accounts known to marmot-app, refreshed after every account-changing call.
    var accounts: [AccountSummaryFfi] = []

    /// The account whose chats / messages are currently displayed.
    /// `nil` during onboarding or while choosing a profile. Restored from and
    /// persisted to UserDefaults so the selection survives relaunch.
    var activeAccountRef: String? {
        didSet {
            if let ref = activeAccountRef {
                returnsToSettingsAfterSelection = false
                prefersProfileSelection = false
                defaults.removeObject(forKey: Self.profileSelectionKey)
                defaults.set(ref, forKey: Self.activeAccountKey)
            } else {
                // Clearing the ref (e.g. signing out of the only account) must
                // remove the persisted value, otherwise the next launch
                // resurrects the signed-out account from UserDefaults.
                defaults.removeObject(forKey: Self.activeAccountKey)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.prefersProfileSelection = defaults.bool(forKey: Self.profileSelectionKey)
        self.activeAccountRef = defaults.string(forKey: Self.activeAccountKey)
    }

    func requestProfileSelection() {
        returnsToSettingsAfterSelection = true
        prefersProfileSelection = true
        defaults.set(true, forKey: Self.profileSelectionKey)
        activeAccountRef = nil
    }

    func resetSelection() {
        returnsToSettingsAfterSelection = false
        activeAccountRef = nil
        prefersProfileSelection = false
        defaults.removeObject(forKey: Self.profileSelectionKey)
    }

    /// The active account summary resolved from the list, or nil.
    var activeAccount: AccountSummaryFfi? {
        guard let ref = activeAccountRef else { return nil }
        return accounts.first { $0.label == ref }
    }
}
