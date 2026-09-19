import Foundation

/// Keep a loaded empty result distinct from a lookup that has not finished.
nonisolated struct SharedGroupsLoadState {
    private var accountRef: String?
    private var peerAccountIdHex: String?
    private(set) var hasLoaded = false

    /// Returns true only when the caller must discard its previous group rows.
    mutating func prepare(accountRef: String?, peerAccountIdHex: String?) -> Bool {
        let peer = peerAccountIdHex?.lowercased()
        guard self.accountRef != accountRef || self.peerAccountIdHex != peer else { return false }
        self.accountRef = accountRef
        self.peerAccountIdHex = peer
        hasLoaded = false
        return true
    }

    mutating func complete(accountRef: String?, peerAccountIdHex: String?) {
        guard let accountRef, let peerAccountIdHex,
              self.accountRef == accountRef,
              self.peerAccountIdHex == peerAccountIdHex.lowercased()
        else { return }
        hasLoaded = true
    }
}
