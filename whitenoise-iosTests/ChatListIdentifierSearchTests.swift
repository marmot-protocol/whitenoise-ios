import Testing
@testable import whitenoise_ios

struct ChatListIdentifierSearchTests {
    private let hex = String(repeating: "ab", count: 32)
    private var npub: String { NostrProfileReference.npub(fromAccountIdHex: hex) ?? "" }
    private var nprofile: String {
        NostrProfileReference.nprofile(
            fromAccountIdHex: hex,
            relayHints: ["wss://relay.example"]
        ) ?? ""
    }

    private func pastedProfileNpub(_ query: String) -> String? {
        guard case .profileReference(let reference) = RecipientIdentifierQuery.classify(query),
              let resolved = RecipientIdentifierQuery.resolvedProfileReference(reference)
        else { return nil }
        return ChatListIdentifierSearch.profileNpub(for: .resolved(resolved))
    }

    @Test func pastedProfileReferencesOpenTheSameProfile() {
        #expect(pastedProfileNpub(npub) == npub)
        #expect(pastedProfileNpub(" nostr:\(npub)\n") == npub)
        #expect(pastedProfileNpub(nprofile) == npub)
        #expect(pastedProfileNpub(hex.uppercased()) == npub)
        #expect(pastedProfileNpub("\(DeepLink.scheme)://profile/\(npub)") == npub)
    }

    @Test func resolvedNip05AddressOpensTheResolvedKeyAsNpub() {
        let resolution = RecipientResolutionState.resolved(ResolvedRecipient(
            accountIdHex: hex,
            memberRef: hex,
            queriedNip05: "alice@example.com"
        ))
        #expect(ChatListIdentifierSearch.profileNpub(for: resolution) == npub)
    }

    @Test func nameShapedQueriesKeepFilteringChats() {
        #expect(RecipientIdentifierQuery.classify("alice smith") == .none)
        #expect(pastedProfileNpub("alice smith") == nil)
        #expect(pastedProfileNpub(String(npub.dropLast()) + "x") == nil)
    }

    @Test(arguments: [
        RecipientResolutionState.idle,
        .resolving,
        .noProfile,
        .failed,
        .invalid,
    ])
    func unresolvedStatesNeverOpenAProfile(_ resolution: RecipientResolutionState) {
        #expect(ChatListIdentifierSearch.profileNpub(for: resolution) == nil)
    }

    private let me = String(repeating: "cd", count: 32)
    private var resolved: RecipientResolutionState {
        .resolved(ResolvedRecipient(accountIdHex: hex, memberRef: hex, queriedNip05: nil))
    }

    private func snapshot(_ groupIdHex: String, name: String?, members: [String]) -> RecipientGroupSnapshot {
        RecipientGroupSnapshot(
            groupIdHex: groupIdHex,
            sanitizedName: name,
            title: name ?? groupIdHex,
            avatarUrl: nil,
            isSelfMember: true,
            lastActivityAt: 1,
            memberIdsHex: members,
            lastSenderIdHex: nil,
            welcomerIdHex: nil
        )
    }

    private func destination(_ snapshots: [RecipientGroupSnapshot]) -> ChatListIdentifierSearch.Destination? {
        ChatListIdentifierSearch.destination(for: resolved, snapshots: snapshots, myAccountIdHex: me)
    }

    @Test func aSingleDirectChatOpensThatChat() {
        let snapshots = [
            snapshot("dm", name: nil, members: [me, hex]),
            snapshot("team", name: "Team", members: [me, hex, String(repeating: "ef", count: 32)]),
        ]
        #expect(destination(snapshots) == .chat(groupIdHex: "dm"))
    }

    @Test func noDirectChatOpensTheProfile() {
        let snapshots = [
            snapshot("pair", name: "Us two", members: [me, hex]),
            snapshot("team", name: "Team", members: [me, hex, String(repeating: "ef", count: 32)]),
        ]
        #expect(destination(snapshots) == .profile(npub: npub))
        #expect(destination([]) == .profile(npub: npub))
    }

    @Test func severalDirectChatsOpenTheProfile() {
        let snapshots = [
            snapshot("dm1", name: nil, members: [me, hex]),
            snapshot("dm2", name: nil, members: [me, hex]),
        ]
        #expect(destination(snapshots) == .profile(npub: npub))
    }

    @Test func ownIdentityOpensTheProfile() {
        let ownResolution = RecipientResolutionState.resolved(
            ResolvedRecipient(accountIdHex: me, memberRef: me, queriedNip05: nil)
        )
        let destination = ChatListIdentifierSearch.destination(
            for: ownResolution,
            snapshots: [snapshot("dm", name: nil, members: [me, hex])],
            myAccountIdHex: me
        )
        #expect(destination == .profile(npub: NostrProfileReference.npub(fromAccountIdHex: me) ?? ""))
    }

    @Test(arguments: [
        RecipientResolutionState.idle,
        .resolving,
        .noProfile,
        .failed,
        .invalid,
    ])
    func unresolvedStatesHaveNoDestination(_ resolution: RecipientResolutionState) {
        #expect(ChatListIdentifierSearch.destination(
            for: resolution,
            snapshots: [snapshot("dm", name: nil, members: [me, hex])],
            myAccountIdHex: me
        ) == nil)
    }
}
