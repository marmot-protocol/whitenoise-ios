import Testing
@testable import darkmatter_ios

/// #98 — relay URL normalization must deduplicate via a Set in O(n) while
/// preserving first-seen order.
struct RelayURLDeduplicationTests {

    @Test func deduplicatesNormalizedURLsPreservingFirstSeenOrder() {
        let input = [
            "wss://relay.b.example",
            "WSS://Relay.A.Example",   // normalizes to wss://relay.a.example
            "wss://relay.a.example",   // duplicate of the previous after normalization
            "https://nope.example",    // dropped: non-websocket scheme
            "wss://relay.b.example"    // duplicate of the first
        ]
        #expect(RelaySettings.normalizedRelayURLs(input) == [
            "wss://relay.b.example",
            "wss://relay.a.example"
        ])
    }

    @Test func emptyAndAllInvalidInputsReturnEmpty() {
        #expect(RelaySettings.normalizedRelayURLs([]).isEmpty)
        #expect(RelaySettings.normalizedRelayURLs(["https://x.example", "not a url", "wss://"]).isEmpty)
    }
}
