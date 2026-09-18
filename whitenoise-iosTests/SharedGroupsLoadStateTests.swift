import Testing
@testable import whitenoise_ios

struct SharedGroupsLoadStateTests {
    @Test func sameProfileRefreshKeepsItsLoadedResult() {
        var state = SharedGroupsLoadState()
        #expect(!state.hasLoaded)
        let firstLoad = state.prepare(accountRef: "alice", peerAccountIdHex: "abcd")
        #expect(firstLoad)
        #expect(!state.hasLoaded)
        state.complete(accountRef: "alice", peerAccountIdHex: "abcd")
        #expect(state.hasLoaded)

        // Foreground refresh must preserve a known result, even an empty one.
        let sameProfile = state.prepare(accountRef: "alice", peerAccountIdHex: "ABCD")
        #expect(!sameProfile)
        #expect(state.hasLoaded)
    }

    @Test func switchingAccountOrPeerClearsLoadedStateAndRejectsOldCompletion() {
        var state = SharedGroupsLoadState()
        _ = state.prepare(accountRef: "alice", peerAccountIdHex: "abcd")
        state.complete(accountRef: "alice", peerAccountIdHex: "abcd")

        let changedAccount = state.prepare(accountRef: "bob", peerAccountIdHex: "abcd")
        #expect(changedAccount)
        state.complete(accountRef: "alice", peerAccountIdHex: "abcd")
        #expect(!state.hasLoaded)
        state.complete(accountRef: "bob", peerAccountIdHex: "abcd")
        #expect(state.hasLoaded)

        let changedPeer = state.prepare(accountRef: "bob", peerAccountIdHex: "ef01")
        #expect(changedPeer)
        state.complete(accountRef: "bob", peerAccountIdHex: "abcd")
        #expect(!state.hasLoaded)
    }

    @Test func incompleteContextNeverBecomesAKnownEmptyResult() {
        var state = SharedGroupsLoadState()
        _ = state.prepare(accountRef: nil, peerAccountIdHex: "abcd")
        state.complete(accountRef: nil, peerAccountIdHex: "abcd")
        #expect(!state.hasLoaded)
        _ = state.prepare(accountRef: "alice", peerAccountIdHex: nil)
        state.complete(accountRef: "alice", peerAccountIdHex: nil)
        #expect(!state.hasLoaded)
    }
}
