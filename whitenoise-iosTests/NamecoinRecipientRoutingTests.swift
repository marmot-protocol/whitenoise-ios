import Foundation
import Testing
@testable import whitenoise_ios

/// Query-routing tests for the Namecoin `.bit` path through
/// RecipientIdentifierQuery and RecipientQueryModel — the iOS equivalent of
/// the linux invite/new-chat wiring: a `.bit` / `d/` / `id/` identifier
/// typed into the recipient field resolves to a pubkey through
/// NamecoinResolver instead of the DNS NIP-05 path.
struct NamecoinRecipientRoutingTests {
    private let hex = String(repeating: "ab", count: 32)

    // MARK: - classification

    @Test func classifiesNamecoinIdentifiers() {
        #expect(RecipientIdentifierQuery.classify("alice@example.bit") == .namecoin("alice@example.bit"))
        #expect(RecipientIdentifierQuery.classify("Example.BIT") == .namecoin("Example.BIT"))
        #expect(RecipientIdentifierQuery.classify("d/example") == .namecoin("d/example"))
        #expect(RecipientIdentifierQuery.classify("id/alice") == .namecoin("id/alice"))
        #expect(RecipientIdentifierQuery.classify("  example.bit  ") == .namecoin("example.bit"))
        #expect(RecipientIdentifierQuery.classify("nostr:example.bit") == .namecoin("nostr:example.bit"))
    }

    @Test func namecoinWinsOverNip05ForBitDomains() {
        // `alice@example.bit` contains an `@` and would parse as a NIP-05
        // address; the `.bit` suffix must route it to Namecoin instead —
        // `.bit` is not DNS.
        if case .namecoin = RecipientIdentifierQuery.classify("alice@example.bit") {
        } else {
            Issue.record("expected namecoin classification")
        }
        // Non-.bit addresses keep the existing NIP-05 behavior.
        #expect(
            RecipientIdentifierQuery.classify("alice@example.com")
                == .nip05(name: "alice", domain: "example.com")
        )
    }

    @Test func profileReferenceStillWinsOverNamecoin() {
        // A bare hex key is never a .bit name, but make the precedence
        // explicit: reference classification runs first.
        if case .profileReference = RecipientIdentifierQuery.classify(hex) {
        } else {
            Issue.record("expected a profile reference")
        }
    }

    // MARK: - query model resolution

    @MainActor
    @Test func namecoinQueryResolvesToRecipient() async {
        let model = RecipientQueryModel()
        model.namecoinResolverForTesting = { _ in
            .resolved(NamecoinResolver.Resolved(
                pubkeyHex: String(repeating: "ab", count: 32),
                relays: [],
                namecoinName: "d/example",
                localPart: "_"
            ))
        }
        let appState = AppState.test()
        model.text = "example.bit"
        model.queryChanged(using: appState)
        #expect(model.resolution == .resolving)
        await model.awaitResolutionForTesting()
        guard case .resolved(let recipient) = model.resolution else {
            Issue.record("expected resolved, got \(model.resolution)")
            return
        }
        #expect(recipient.accountIdHex == String(repeating: "ab", count: 32))
        #expect(recipient.memberRef == String(repeating: "ab", count: 32))
        #expect(recipient.queriedNip05 == nil)
    }

    @MainActor
    @Test func namecoinNotFoundAndUnavailableMapToRowStates() async {
        let model = RecipientQueryModel()
        let appState = AppState.test()

        model.namecoinResolverForTesting = { _ in .notFound }
        model.text = "ghost.bit"
        model.queryChanged(using: appState)
        await model.awaitResolutionForTesting()
        #expect(model.resolution == .noProfile)

        model.namecoinResolverForTesting = { _ in .unavailable }
        model.text = "example.bit"
        model.queryChanged(using: appState)
        await model.awaitResolutionForTesting()
        #expect(model.resolution == .failed)
    }

    @MainActor
    @Test func typingOnCancelsAnInFlightNamecoinResolve() async {
        // The iOS equivalent of the linux pending-intent snapshot rules: a
        // resolve started for one query must not land its result after the
        // user edited the field — the generation guard drops it.
        let model = RecipientQueryModel()
        let appState = AppState.test()
        let gate = ResolutionGate()
        model.namecoinResolverForTesting = { _ in
            await gate.suspendUntilReleased()
            return .resolved(NamecoinResolver.Resolved(
                pubkeyHex: String(repeating: "cd", count: 32),
                relays: [],
                namecoinName: "d/example",
                localPart: "_"
            ))
        }
        model.text = "example.bit"
        model.queryChanged(using: appState)
        // Edit the field before the resolver lands: the stale result must
        // not be adopted.
        model.text = "alice"
        model.queryChanged(using: appState)
        await gate.release()
        #expect(model.resolution == .idle)
    }
}

private actor ResolutionGate {
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?

    func suspendUntilReleased() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}
