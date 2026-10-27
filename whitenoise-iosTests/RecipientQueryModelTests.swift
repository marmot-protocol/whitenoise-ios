import Testing
@testable import whitenoise_ios

/// The recipient search field's state machine. Classification itself is
/// `RecipientIdentifierQueryTests`; this checks what the model does with it:
/// public keys resolve locally, NIP-05 results map to resolution states, and
/// a cleared or replaced query never adopts a stale lookup. Lookups are
/// injected, so nothing here touches the network.
@MainActor
struct RecipientQueryModelTests {
    private let accountIdHex = hex("ab")
    private var npub: String { NostrProfileReference.npub(fromAccountIdHex: accountIdHex) ?? "" }

    /// A lookup that answers per address once the test releases it.
    @MainActor
    private final class ControlledLookup {
        var answers: [String: Nip05Resolver.Resolution] = [:]
        var gates: [String: TestLatch] = [:]
        private(set) var started: [String] = []

        func lookUp(_ name: String, _ domain: String) async -> Nip05Resolver.Resolution {
            let address = "\(name)@\(domain)"
            started.append(address)
            if let gate = gates[address] { await gate.hold() }
            return answers[address] ?? .failed
        }
    }

    private func model(_ lookup: ControlledLookup) -> RecipientQueryModel {
        RecipientQueryModel(lookUpNip05: { await lookup.lookUp($0, $1) }, debounce: {})
    }

    @Test func aPublicKeyResolvesLocallyWithoutALookup() async {
        let lookup = ControlledLookup()
        let model = model(lookup)
        model.text = npub

        model.queryChanged(using: AppState.test())
        await model.awaitResolutionForTesting()

        #expect(model.resolution == .resolved(ResolvedRecipient(
            accountIdHex: accountIdHex, memberRef: npub, queriedNip05: nil)))
        #expect(lookup.started.isEmpty)
    }

    @Test func plainTextReplacesAResolvedRecipientWithIdle() {
        let model = model(ControlledLookup())
        let appState = AppState.test()
        model.text = npub
        model.queryChanged(using: appState)
        #expect(model.resolution == .resolved(ResolvedRecipient(
            accountIdHex: accountIdHex, memberRef: npub, queriedNip05: nil)))

        model.text = "Alice"
        model.queryChanged(using: appState)

        #expect(model.resolution == .idle)
    }

    @Test(arguments: [
        (Nip05Resolver.Resolution.noProfile, RecipientResolutionState.noProfile),
        (.failed, .failed),
        (.invalidAddress, .invalid),
    ])
    func aNip05OutcomeBecomesTheResolution(_ outcome: Nip05Resolver.Resolution,
                                           _ expected: RecipientResolutionState) async {
        let lookup = ControlledLookup()
        lookup.answers["alice@example.com"] = outcome
        let model = model(lookup)
        model.text = "Alice@Example.com"

        model.queryChanged(using: AppState.test())
        #expect(model.resolution == .resolving)
        await model.awaitResolutionForTesting()

        #expect(lookup.started == ["alice@example.com"])
        #expect(model.resolution == expected)
    }

    /// A NIP-05 match selects the resolved key, not the address, and keeps
    /// the address so the row can show whether the profile declares it.
    @Test func aNip05MatchResolvesToItsKeyAndRemembersTheAddress() async {
        let lookup = ControlledLookup()
        lookup.answers["alice@example.com"] = .resolved(accountIdHex: accountIdHex)
        let model = model(lookup)
        model.text = "alice@example.com"

        model.queryChanged(using: AppState.test())
        await model.awaitResolutionForTesting()

        #expect(model.resolution == .resolved(ResolvedRecipient(
            accountIdHex: accountIdHex, memberRef: accountIdHex, queriedNip05: "alice@example.com")))
    }

    /// Each lookup is a network fetch, so an address replaced or cleared while
    /// its debounce is still running is never looked up at all.
    @Test func anAddressChangedDuringItsDebounceIsNeverLookedUp() async throws {
        let lookup = ControlledLookup()
        var debounces = 0
        let model = RecipientQueryModel(lookUpNip05: { await lookup.lookUp($0, $1) }, debounce: {
            debounces += 1
            // Ends only when the lookup is cancelled; if cancellation broke it
            // throws after its timeout and the lookup check below fails.
            try await parkUntilCancelled()
        })
        let appState = AppState.test()

        model.text = "alice@example.com"
        model.queryChanged(using: appState)
        try await eventually { debounces == 1 }
        model.text = "bob@example.com"
        model.queryChanged(using: appState)
        try await eventually { debounces == 2 }
        model.clear()
        await model.awaitResolutionForTesting()

        #expect(lookup.started.isEmpty)
        #expect(model.resolution == .idle)
    }

    @Test func aClearedQueryNeverAdoptsItsLookup() async throws {
        let lookup = ControlledLookup()
        let release = TestLatch()
        // Released on every exit, so a failed wait never leaves the lookup parked.
        defer { release.signal() }
        lookup.gates["alice@example.com"] = release
        lookup.answers["alice@example.com"] = .resolved(accountIdHex: accountIdHex)
        let model = model(lookup)
        model.text = "alice@example.com"
        model.queryChanged(using: AppState.test())
        try await eventually { lookup.started == ["alice@example.com"] }

        model.clear()
        release.signal()
        await model.awaitResolutionForTesting()

        #expect(model.resolution == .idle)
    }

    @Test func aReplacedQueryKeepsTheNewerResult() async throws {
        let lookup = ControlledLookup()
        let releaseAlice = TestLatch()
        defer { releaseAlice.signal() }
        lookup.gates["alice@example.com"] = releaseAlice
        lookup.answers["alice@example.com"] = .resolved(accountIdHex: accountIdHex)
        lookup.answers["bob@example.com"] = .noProfile
        let model = model(lookup)
        let appState = AppState.test()
        model.text = "alice@example.com"
        model.queryChanged(using: appState)
        try await eventually { lookup.started == ["alice@example.com"] }

        model.text = "bob@example.com"
        model.queryChanged(using: appState)
        try await eventually { model.resolution == .noProfile }
        // Alice's lookup answers only after Bob's result is in place.
        releaseAlice.signal()
        await model.awaitResolutionForTesting()

        #expect(lookup.started == ["alice@example.com", "bob@example.com"])
        #expect(model.resolution == .noProfile)
    }
}
