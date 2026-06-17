import Testing
@testable import darkmatter_ios

/// #77 — hex validation/normalization is consolidated into one strict-ASCII
/// `Hex` utility shared across DeepLink, NostrProfileReference, and
/// MessageSemantics.
struct HexValidationTests {
    private let valid64 = String(repeating: "a", count: 64)

    @Test func isHexAcceptsAsciiHexOfAnyLength() {
        #expect(Hex.isHex("0"))
        #expect(Hex.isHex("deadBEEF00"))
        #expect(Hex.isHex(valid64))
    }

    @Test func isHexRejectsEmptyAndNonAsciiHexDigits() {
        #expect(!Hex.isHex(""))
        #expect(!Hex.isHex("xyz"))
        #expect(!Hex.isHex("dead beef"))
        // Character.isHexDigit accepts these; the strict ASCII check must not, so
        // peer-controlled content cannot masquerade as a valid identifier.
        #expect(!Hex.isHex("１２３４"))      // fullwidth digits U+FF11…
        #expect(!Hex.isHex("dead𝟨eef"))     // U+1D7E8 MATHEMATICAL SANS-SERIF DIGIT SIX
    }

    @Test func is32BytesRequiresExactly64AsciiHexChars() {
        #expect(Hex.is32Bytes(valid64))
        #expect(Hex.is32Bytes(valid64.uppercased()))
        #expect(!Hex.is32Bytes(String(repeating: "a", count: 63)))
        #expect(!Hex.is32Bytes(String(repeating: "a", count: 65)))
        #expect(!Hex.is32Bytes(String(repeating: "g", count: 64)))
    }

    @Test func normalized32BytesTrimsValidatesAndLowercases() {
        #expect(Hex.normalized32Bytes("  \(valid64.uppercased())  ") == valid64)
        #expect(Hex.normalized32Bytes(nil) == nil)
        #expect(Hex.normalized32Bytes("") == nil)
        #expect(Hex.normalized32Bytes(String(repeating: "a", count: 63)) == nil)
    }
}

/// #33 — Bech32 charset lookup is now an O(1) dictionary; decoding must remain
/// byte-for-byte identical for known references.
struct Bech32CharsetLookupTests {

    private let npub = "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"
    private let nprofile = "nprofile1qqsrhuxx8l9ex335q7he0f09aej04zpazpl0ne2cgukyawd24mayt8gpp4mhxue69uhhytnc9e3k7mgpz4mhxue69uhkg6nzv9ejuumpv34kytnrdaksjlyr9p"
    private let nprofileHex = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"

    @Test func memberRefAcceptsChecksumValidNpub() {
        #expect(NostrProfileReference.memberRef(fromReference: npub) == npub)
    }

    @Test func memberRefRejectsNpubWithBadChecksum() {
        #expect(NostrProfileReference.memberRef(fromReference: "npub1" + String(repeating: "q", count: 58)) == nil)
    }

    @Test func memberRefNormalizesUppercaseNpubToLowercase() {
        // BIP-173 permits all-uppercase bech32 and bech32Decode accepts it, so
        // an uppercase npub must normalize to the canonical lowercase form to
        // match the hex/nprofile branches and de-dup correctly downstream (#232).
        #expect(NostrProfileReference.memberRef(fromReference: npub.uppercased()) == npub)
    }

    @Test func decodesKnownNprofileToPubkeyHex() {
        #expect(NostrProfileReference.memberRef(fromReference: nprofile) == nprofileHex)
    }

    @Test func rejectsReferenceWithCharacterOutsideCharset() {
        // 'b' is not part of the bech32 charset, so a data part containing it
        // must fail the lookup and decode to nil rather than misindex.
        #expect(NostrProfileReference.memberRef(fromReference: "nprofile1bbbbbb") == nil)
    }

    @Test func rejectsOverlongBech32ReferencesBeforeDecode() {
        let overlongNpub = "npub1" + String(repeating: "q", count: 300)
        let overlongNprofile = "nprofile1" + String(repeating: "q", count: 300)

        #expect(NostrProfileReference.memberRef(fromReference: overlongNpub) == nil)
        #expect(NostrProfileReference.pubkeyHex(fromBech32: overlongNpub) == nil)
        #expect(NostrProfileReference.memberRef(from: "nostr:\(overlongNprofile)") == nil)
        #expect(DeepLink.parse(string: overlongNpub) == nil)
        #expect(DeepLink.parse(string: "darkmatter://profile/\(overlongNprofile)") == nil)
    }
}
