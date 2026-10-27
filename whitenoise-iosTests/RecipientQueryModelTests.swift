import Testing
@testable import whitenoise_ios

/// The recipient search field's state machine. Classification itself is
/// `RecipientIdentifierQueryTests`; this checks what the model does with it:
/// public keys resolve locally, NIP-05 addresses wait for a debounced lookup,
/// and a cleared or replaced query never adopts a stale lookup.
@MainActor
struct RecipientQueryModelTests {
    private let accountIdHex = hex("ab")
    private var npub: String { NostrProfileReference.npub(fromAccountIdHex: accountIdHex) ?? "" }

    @Test func plainTextStaysIdleAndBrowsesKnownPeople() {
        let model = RecipientQueryModel()
        model.text = "  Alice  "

        model.queryChanged(using: AppState.test())

        #expect(model.resolution == .idle)
        #expect(!model.isIdentifierQuery)
        #expect(model.trimmedText == "Alice")
    }

    @Test func aPublicKeyResolvesLocallyWithoutALookup() {
        let model = RecipientQueryModel()
        model.text = npub

        model.queryChanged(using: AppState.test())

        #expect(model.isIdentifierQuery)
        #expect(model.resolution == .resolved(ResolvedRecipient(
            accountIdHex: accountIdHex, memberRef: npub, queriedNip05: nil)))
    }

    @Test func aNip05AddressWaitsForItsLookup() {
        let model = RecipientQueryModel()
        model.text = "alice@example.com"

        model.queryChanged(using: AppState.test())

        #expect(model.isIdentifierQuery)
        #expect(model.resolution == .resolving)
        model.clear()
    }

    @Test func clearingAPendingLookupResetsTheField() {
        let model = RecipientQueryModel()
        model.text = "alice@example.com"
        model.queryChanged(using: AppState.test())

        model.clear()

        #expect(model.text.isEmpty)
        #expect(model.resolution == .idle)
        #expect(!model.isIdentifierQuery)
    }

    @Test func aPublicKeyReplacesAPendingLookupAtOnce() {
        let model = RecipientQueryModel()
        let appState = AppState.test()
        model.text = "alice@example.com"
        model.queryChanged(using: appState)

        model.text = npub
        model.queryChanged(using: appState)

        #expect(model.resolution == .resolved(ResolvedRecipient(
            accountIdHex: accountIdHex, memberRef: npub, queriedNip05: nil)))
    }
}
