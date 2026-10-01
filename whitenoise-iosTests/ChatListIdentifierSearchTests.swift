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
}
