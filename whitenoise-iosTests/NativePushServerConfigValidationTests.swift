import Testing
@testable import whitenoise_ios

/// #72 — the push server config must reject a pubkey that is not 64-char hex
/// rather than passing a malformed value through to push registration.
struct NativePushServerConfigValidationTests {
    private let validPubkey = "73a4996bd18de19f6ac5f6ad42f5f2671eba6e5b739ea9695f07b00b0693fc04"

    @Test func acceptsValid64CharHexPubkeyAndNormalizesCase() {
        let config = NativePushServerConfig.current(
            rawPubkey: "  \(validPubkey.uppercased())  ",
            rawRelayHint: " WSS://Relay.Example/Nostr?Token=ABC "
        )
        #expect(config?.serverPubkeyHex == validPubkey)
        #expect(config?.relayHint == "wss://relay.example/Nostr?Token=ABC")
    }

    @Test func rejectsMissingEmptyOrMalformedPubkey() {
        #expect(NativePushServerConfig.current(rawPubkey: nil, rawRelayHint: nil) == nil)
        #expect(NativePushServerConfig.current(rawPubkey: "", rawRelayHint: nil) == nil)
        #expect(NativePushServerConfig.current(rawPubkey: "not-hex", rawRelayHint: nil) == nil)
        #expect(NativePushServerConfig.current(
            rawPubkey: String(repeating: "a", count: 63), rawRelayHint: nil
        ) == nil)
    }

    @Test func dropsBlankRelayHintToNil() {
        let config = NativePushServerConfig.current(
            rawPubkey: validPubkey,
            rawRelayHint: "   "
        )
        #expect(config?.serverPubkeyHex == validPubkey)
        #expect(config?.relayHint == nil)
    }

    @Test func dropsMalformedRelayHintToNil() {
        for relayHint in ["https://relay.example", "relay.example", "wss://", "ws://\n", "not a relay"] {
            let config = NativePushServerConfig.current(
                rawPubkey: validPubkey,
                rawRelayHint: relayHint
            )

            #expect(config?.serverPubkeyHex == validPubkey)
            #expect(config?.relayHint == nil)
        }
    }

    @Test func relayHintPolicyNormalizesSeedRelaysBeforeMembershipCheck() throws {
        let config = try #require(NativePushServerConfig.current(
            rawPubkey: validPubkey,
            rawRelayHint: " WSS://Relay.Example/Nostr "
        ))

        #expect(NativePushRelayHintPolicy.relayHint(
            from: config,
            seedRelays: [" wss://relay.other.example ", "WSS://Relay.Example/Nostr"],
            defaultRelayHint: "wss://fallback.example"
        ) == "wss://relay.example/Nostr")
    }

    @Test func relayHintPolicyNormalizesFallbackRelayHint() {
        let config = NativePushServerConfig(serverPubkeyHex: validPubkey, relayHint: "wss://unknown.example")

        #expect(NativePushRelayHintPolicy.relayHint(
            from: config,
            seedRelays: ["wss://relay.example"],
            defaultRelayHint: " WSS://Fallback.Example "
        ) == "wss://fallback.example")
    }
}
