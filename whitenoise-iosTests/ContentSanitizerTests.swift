import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

struct ContentSanitizerTests {

    @Test func stripsBidiOverrideFromName() {
        // Trojan-Source-style: an RLO (U+202E) can reverse rendering to spoof.
        let spoofed = "alice\u{202E}evil"
        let safe = ContentSanitizer.displayName(spoofed)
        #expect(safe == "aliceevil")
        #expect(!(safe?.unicodeScalars.contains { $0.value == 0x202E } ?? false))
    }

    @Test func collapsesNewlinesInName() {
        let multiline = "line one\nline two\t\tmore"
        let safe = ContentSanitizer.displayName(multiline)
        #expect(safe == "line one line two more")
    }

    @Test func capsNameLength() {
        let long = String(repeating: "a", count: 500)
        let safe = ContentSanitizer.displayName(long)
        #expect((safe?.count ?? 0) <= ContentSanitizer.maxNameLength)
    }

    @Test func emptyAfterStrippingReturnsNil() {
        #expect(ContentSanitizer.displayName("\u{202E}\u{200B}") == nil)
        #expect(ContentSanitizer.displayName("\u{200D}\u{2060}\u{3164}") == nil)
        #expect(ContentSanitizer.displayName("   ") == nil)
        #expect(ContentSanitizer.displayName(nil) == nil)
    }

    @Test func verticalSeparatorsAreRemovedBeforeBlankLineClamp() {
        #expect(ContentSanitizer.messageBody("hello\u{2028}\u{2029}world") == "helloworld")
        #expect(ContentSanitizer.multilineText("about\u{2028}\u{2029}text") == "abouttext")
    }

    @Test func namesAndReactionsHaveScalarBudgets() {
        let megaCluster = "a" + String(repeating: "\u{0301}", count: 2_000)

        let name = ContentSanitizer.displayName(megaCluster)
        #expect(name?.count == 1)
        #expect((name?.unicodeScalars.count ?? 0) <= ContentSanitizer.maxNameLength * 8)

        let reaction = ContentSanitizer.reactionEmoji(megaCluster)
        #expect(reaction.count == 1)
        #expect(reaction.unicodeScalars.count <= ContentSanitizer.maxReactionLength * 8)
    }

    @Test func relayDisplayLineStripsInvisibleLetterScalars() {
        #expect(ContentSanitizer.relayDisplayLine("relay\u{115F}\u{1160}\u{3164}\u{FFA0}\u{2800}.example", maxLength: 80) == "relay.example")
    }

    @Test func compactSingleLineStripsInvisibleFormatAndBlankScalars() {
        #expect(
            ContentSanitizer.compactSingleLine(
                "before\u{200D}\u{2060}\u{3164}after",
                maxLength: 80
            ) == "beforeafter"
        )
        #expect(ContentSanitizer.compactSingleLine("\u{3164}", maxLength: 80) == nil)
    }

    @Test func imageURLAllowsHttps() {
        #expect(ContentSanitizer.imageURL("https://example.com/a.png") != nil)
        #expect(ContentSanitizer.imageURL("http://example.com/a.png") == nil)
    }

    @Test func imageURLRejectsNonStandardPorts() {
        // A peer URL with an explicit port would drive TLS connections at
        // arbitrary ports on public hosts — a connect/timing oracle.
        #expect(ContentSanitizer.imageURL("https://example.com:443/a.png") != nil)
        #expect(ContentSanitizer.imageURL("https://example.com:1234/a.png") == nil)
        #expect(ContentSanitizer.imageURL("https://example.com:8443/a.png") == nil)
        #expect(ContentSanitizer.imageURL("https://example.com:80/a.png") == nil)
    }

    @Test func imageURLRejectsUserInfo() {
        #expect(ContentSanitizer.imageURL("https://user@example.com/a.png") == nil)
        #expect(ContentSanitizer.imageURL("https://user:password@example.com/a.png") == nil)
    }

    @Test func imageURLRejectsOverLengthStrings() {
        // Peer-controlled fields (kind:0 `picture`, group `avatarUrl`, DuckDuckGo
        // results) are unbounded; reject before parsing past the length cap (#381).
        let cap = ContentSanitizer.maxImageURLLength
        let prefix = "https://example.com/"
        // A well-formed HTTPS URL at exactly the cap is still accepted.
        let atCap = prefix + String(repeating: "a", count: cap - prefix.count)
        #expect(atCap.count == cap)
        #expect(ContentSanitizer.imageURL(atCap) != nil)
        // One character over the cap is rejected outright, even though the URL
        // is otherwise valid (HTTPS, public host).
        let overCap = atCap + "a"
        #expect(overCap.count == cap + 1)
        #expect(ContentSanitizer.imageURL(overCap) == nil)
        let utf8OverCap = prefix + String(repeating: "é", count: cap - prefix.count)
        #expect(utf8OverCap.count == cap)
        #expect(utf8OverCap.utf8.count > cap)
        #expect(ContentSanitizer.imageURL(utf8OverCap) == nil)
        // A multi-megabyte hostile value is rejected without parsing it.
        let huge = prefix + String(repeating: "a", count: 4_000_000)
        #expect(ContentSanitizer.imageURL(huge) == nil)
        // Leading/trailing whitespace is trimmed before the length check, so a
        // valid URL padded with whitespace still passes.
        #expect(ContentSanitizer.imageURL("  https://example.com/a.png  ") != nil)
    }

    @Test func imageURLRejectsDangerousSchemes() {
        #expect(ContentSanitizer.imageURL("data:image/png;base64,AAAA") == nil)
        #expect(ContentSanitizer.imageURL("file:///etc/passwd") == nil)
        #expect(ContentSanitizer.imageURL("javascript:alert(1)") == nil)
        #expect(ContentSanitizer.imageURL("ftp://example.com/x") == nil)
        #expect(ContentSanitizer.imageURL("https://") == nil) // no host
        #expect(ContentSanitizer.imageURL("not a url") == nil)
    }

    @Test func imageURLRejectsPrivateAndLoopbackHosts() {
        #expect(ContentSanitizer.imageURL("https://localhost/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://127.0.0.1/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://0.0.0.0/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://0.1.2.3/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://10.1.2.3/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://172.16.0.1/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://172.31.255.255/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://192.168.1.10/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://169.254.169.254/latest/meta-data/") == nil)
        #expect(ContentSanitizer.imageURL("https://[::]/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://[0:0:0:0:0:0:0:0]/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://[::1]/avatar.png") == nil)

        #expect(ContentSanitizer.imageURL("https://172.32.0.1/avatar.png") != nil)
    }

    @Test func imageURLRejectsSharedAddressSpaceAndOtherReservedIPv4() {
        // RFC 6598 Carrier-Grade-NAT / shared address space (100.64.0.0/10).
        #expect(ContentSanitizer.imageURL("https://100.64.0.1/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://100.64.0.0/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://100.100.50.25/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://100.127.255.255/avatar.png") == nil)
        // RFC 6890 IETF protocol assignments (192.0.0.0/24).
        #expect(ContentSanitizer.imageURL("https://192.0.0.1/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://192.0.0.255/avatar.png") == nil)
        // Multicast (224.0.0.0/4) and reserved/future-use (240.0.0.0/4).
        #expect(ContentSanitizer.imageURL("https://224.0.0.1/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://239.255.255.255/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://240.0.0.1/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://255.255.255.255/avatar.png") == nil)

        // Boundaries just outside the blocked ranges remain reachable.
        #expect(ContentSanitizer.imageURL("https://100.63.255.255/avatar.png") != nil)
        #expect(ContentSanitizer.imageURL("https://100.128.0.1/avatar.png") != nil)
        #expect(ContentSanitizer.imageURL("https://192.0.1.1/avatar.png") != nil)
        #expect(ContentSanitizer.imageURL("https://223.255.255.255/avatar.png") != nil)
    }

    @Test func imageURLRejectsLegacyIPv4LiteralBypasses() {
        #expect(ContentSanitizer.imageURL("https://127.0.0.1./avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://2130706433/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://0x7f000001/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://017700000001/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://127.1/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://012.0.0.1/avatar.png") == nil)
    }

    @Test func imageURLRejectsIPv4MappedIPv6PrivateAndLoopbackHosts() {
        #expect(ContentSanitizer.imageURL("https://[::ffff:127.0.0.1]/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://[::ffff:10.1.2.3]/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://[::ffff:172.16.0.1]/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://[::ffff:192.168.1.10]/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://[::ffff:c0a8:010a]/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://[0:0:0:0:0:ffff:169.254.169.254]/latest/meta-data/") == nil)

        #expect(ContentSanitizer.imageURL("https://[::ffff:8.8.8.8]/avatar.png") != nil)
    }

    @Test func imageURLRejectsIPv4CompatibleIPv6PrivateAndLoopbackHosts() {
        #expect(ContentSanitizer.imageURL("https://[::127.0.0.1]/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://[::10.1.2.3]/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://[::172.16.0.1]/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://[::192.168.1.10]/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://[::169.254.169.254]/latest/meta-data/") == nil)
        #expect(ContentSanitizer.imageURL("https://[0:0:0:0:0:0:c0a8:010a]/avatar.png") == nil)

        #expect(ContentSanitizer.imageURL("https://[::8.8.8.8]/avatar.png") != nil)
    }

    @Test func imageURLRejectsSIITAndNAT64IPv4Embeddings() {
        #expect(ContentSanitizer.imageURL("https://[::ffff:0:127.0.0.1]/avatar.png") == nil)
        #expect(ContentSanitizer.imageURL("https://[::ffff:0:169.254.169.254]/latest/meta-data/") == nil)
        #expect(ContentSanitizer.imageURL("https://[64:ff9b::a9fe:a9fe]/latest/meta-data/") == nil)
        #expect(ContentSanitizer.imageURL("https://[64:ff9b::127.0.0.1]/avatar.png") == nil)

        #expect(ContentSanitizer.imageURL("https://[::ffff:0:8.8.8.8]/avatar.png") != nil)
        #expect(ContentSanitizer.imageURL("https://[64:ff9b::808:808]/avatar.png") != nil)
    }

    @Test func profileAddressNormalizesSimpleAddressFields() {
        #expect(ContentSanitizer.profileAddress(" Alice+Tips@Example.COM ") == "alice+tips@example.com")
        #expect(ContentSanitizer.profileAddress("alice@example.com") == "alice@example.com")
    }

    @Test func profileAddressRejectsMalformedOrOversizedValues() {
        #expect(ContentSanitizer.profileAddress("alice") == nil)
        #expect(ContentSanitizer.profileAddress("alice@localhost") == nil)
        #expect(ContentSanitizer.profileAddress("alice@-example.com") == nil)
        #expect(ContentSanitizer.profileAddress("alice@example-.com") == nil)
        #expect(ContentSanitizer.profileAddress("alice@exa_mple.com") == nil)
        #expect(ContentSanitizer.profileAddress("a b@example.com") == nil)
        #expect(ContentSanitizer.profileAddress(String(repeating: "a", count: 65) + "@example.com") == nil)
        #expect(ContentSanitizer.profileAddress("alice@" + String(repeating: "a", count: 250) + ".com") == nil)
    }

    @Test func profileAddressRejectsIPLiteralAndNumericDomains() {
        #expect(ContentSanitizer.profileAddress("alice@127.0.0.1") == nil)
        #expect(ContentSanitizer.profileAddress("bob@10.0.0.1") == nil)
        #expect(ContentSanitizer.profileAddress("x@169.254.169.254") == nil)
        #expect(ContentSanitizer.profileAddress("alice@8.8.8.8") == nil)
        #expect(ContentSanitizer.profileAddress("alice@0x7f.0.0.1") == nil)
        #expect(ContentSanitizer.profileAddress("alice@123.456") == nil)
        #expect(ContentSanitizer.profileAddress("alice@example.123") == nil)
    }

    // MARK: - Message bodies

    @Test func messageBodyStripsBidiButKeepsNewlines() {
        let raw = "first line\u{202E}spoof\nsecond line"
        let safe = ContentSanitizer.messageBody(raw)
        #expect(!safe.unicodeScalars.contains { $0.value == 0x202E })
        #expect(safe.contains("\n"))            // newline preserved
        #expect(safe == "first linespoof\nsecond line")
    }

    @Test func messageBodyClampsBlankLineFlooding() {
        let raw = "top\n\n\n\n\n\n\n\nbottom"
        let safe = ContentSanitizer.messageBody(raw)
        #expect(safe == "top\n\nbottom")        // 3+ blank lines → 2
    }

    @Test func messageBodyCapsLength() {
        let raw = String(repeating: "x", count: ContentSanitizer.maxMessageLength + 500)
        #expect(ContentSanitizer.messageBody(raw).count == ContentSanitizer.maxMessageLength)
    }

    @Test func messageBodyTrimsOuterWhitespace() {
        #expect(ContentSanitizer.messageBody("  \n hello \n  ") == "hello")
    }

    // MARK: - Group names

    @Test func groupNameSingleLinesAndStripsBidi() {
        let raw = "Secret\u{202E}evil\nClub"
        let safe = ContentSanitizer.groupName(raw)
        #expect(safe == "Secretevil Club")      // bidi gone, newline → space
    }

    @Test func groupNameCaps() {
        let raw = String(repeating: "g", count: 400)
        #expect((ContentSanitizer.groupName(raw)?.count ?? 0) <= ContentSanitizer.maxGroupNameLength)
    }

    @Test func groupNameEmptyIsNil() {
        #expect(ContentSanitizer.groupName("") == nil)
        #expect(ContentSanitizer.groupName("\u{202E}\u{200B}") == nil)
    }

    // Encrypted-media locators route through `ContentSanitizer.imageURL`, so a
    // private-range host must be refused at the locator boundary as well.
    @Test func mediaLocatorStaticValidationAllowsOnlyPublicHttpsBlossom() {
        #expect(EncryptedMediaLocatorValidation.isStaticallySafe([
            blossomLocator("https://media.example/blob"),
        ]))
        #expect(!EncryptedMediaLocatorValidation.isStaticallySafe([
            blossomLocator("http://media.example/blob"),
        ]))
        #expect(!EncryptedMediaLocatorValidation.isStaticallySafe([
            blossomLocator("https://user:password@media.example/blob"),
        ]))
        #expect(!EncryptedMediaLocatorValidation.isStaticallySafe([
            blossomLocator("https://media.example:8443/blob"),
        ]))
        #expect(!EncryptedMediaLocatorValidation.isStaticallySafe([
            blossomLocator("not a url"),
        ]))
        #expect(!EncryptedMediaLocatorValidation.isStaticallySafe([
            blossomLocator("https://127.0.0.1/blob"),
        ]))
        #expect(!EncryptedMediaLocatorValidation.isStaticallySafe([
            blossomLocator("https://service.localhost/blob"),
        ]))
        #expect(!EncryptedMediaLocatorValidation.isStaticallySafe([
            blossomLocator("https://media.example/blob"),
            blossomLocator("https://10.0.0.5/private"),
        ]))
        #expect(EncryptedMediaLocatorValidation.isStaticallySafe([
            MediaLocatorFfi(kind: "ipfs-v1", value: "https://10.0.0.5/private"),
            blossomLocator("https://media.example/blob"),
        ]))
        #expect(!EncryptedMediaLocatorValidation.isStaticallySafe([
            MediaLocatorFfi(kind: "ipfs-v1", value: "https://media.example/blob"),
        ]))
    }

    private func blossomLocator(_ value: String) -> MediaLocatorFfi {
        MediaLocatorFfi(kind: EncryptedMediaLocatorValidation.blossomKind, value: value)
    }

    // MARK: - Multiline text

    @Test func clampsRunsOfBlankLines() {
        let flooded = "Line one" + String(repeating: "\n", count: 8) + "Line two"
        #expect(ContentSanitizer.multilineText(flooded) == "Line one\n\nLine two")
    }

    @Test func clampsCRLFAndLoneCRBlankLineRuns() {
        let crlf = "Line one" + String(repeating: "\r\n", count: 5) + "Line two"
        #expect(ContentSanitizer.multilineText(crlf) == "Line one\n\nLine two")
        let cr = "Line one" + String(repeating: "\r", count: 5) + "Line two"
        #expect(ContentSanitizer.multilineText(cr) == "Line one\n\nLine two")
    }

    @Test func keepsASingleBlankLineAndStripsBidi() {
        let raw = "Para one\n\nPara\u{202E}two"
        #expect(ContentSanitizer.multilineText(raw) == "Para one\n\nParatwo")
    }

    @Test func emptyOrWhitespaceOnlyReturnsNil() {
        #expect(ContentSanitizer.multilineText("\n\n\n\n") == nil)
        #expect(ContentSanitizer.multilineText("   ") == nil)
        #expect(ContentSanitizer.multilineText(nil) == nil)
    }

    // MARK: - Relay display lines

    @Test func stripsZeroWidthNonJoinerJoinerAndWordJoiner() {
        let spoofed = "wss://re\u{200C}lay\u{200D}evil\u{2060}.example"
        let display = ContentSanitizer.relayDisplayLine(spoofed, maxLength: 120)
        #expect(display == "wss://relayevil.example")
    }

    @Test func stripsTheFullInvisibleFormatFamily() {
        let spoofed = "wss://x"
            + "\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}"
            + "\u{2066}\u{2067}\u{2068}\u{2069}\u{061C}\u{200B}\u{FEFF}"
            + "\u{200C}\u{200D}\u{2060}"
            + ".example"
        #expect(ContentSanitizer.relayDisplayLine(spoofed, maxLength: 120) == "wss://x.example")
    }

    @Test func collapsesWhitespaceLikeSingleLine() {
        let display = ContentSanitizer.relayDisplayLine("  wss://relay\t\n  spaced.example  ", maxLength: 120)
        #expect(display == "wss://relay spaced.example")
    }

    @Test func cleanRelayPassesThroughUnchanged() {
        #expect(ContentSanitizer.relayDisplayLine("wss://relay.example", maxLength: 120) == "wss://relay.example")
    }

    @Test func emptyOrFormatOnlyReturnsNil() {
        #expect(ContentSanitizer.relayDisplayLine(nil, maxLength: 120) == nil)
        #expect(ContentSanitizer.relayDisplayLine("   ", maxLength: 120) == nil)
        #expect(ContentSanitizer.relayDisplayLine("\u{200C}\u{200D}\u{2060}\u{FEFF}", maxLength: 120) == nil)
    }

    @Test func capsLength() {
        let long = "wss://" + String(repeating: "a", count: 200) + ".example"
        let display = ContentSanitizer.relayDisplayLine(long, maxLength: 120)
        #expect((display?.count ?? 0) <= 120)
    }

    @Test func reactionEmojiStillPreservesZWJSequences() {
        #expect(ContentSanitizer.reactionEmoji("👨‍👩‍👧") == "👨‍👩‍👧") // ZWJ family
        #expect(ContentSanitizer.reactionEmoji("❤️") == "❤️")           // U+FE0F variation selector
    }

    @Test func singleLineStillPreservesFormatCharacters() {
        let withZWJ = "a\u{200D}b"
        #expect(ContentSanitizer.singleLine(withZWJ, maxLength: 80) == withZWJ)
    }

    // MARK: - Remote media address literals

    @Test(arguments: [
        "192.0.2.0", "192.0.2.255", "192.88.99.0", "192.88.99.255",
        "198.18.0.0", "198.19.255.255", "198.51.100.0", "198.51.100.255",
        "203.0.113.0", "203.0.113.255", "192.0.0.9", "192.0.0.10",
        "fec0::", "feff:ffff:ffff:ffff:ffff:ffff:ffff:ffff",
        "100::", "100::ffff:ffff:ffff:ffff", "100:0:0:1::1",
        "2001:db8::", "2001:db8:ffff:ffff:ffff:ffff:ffff:ffff",
        "2001:2::", "2001:2:0:ffff:ffff:ffff:ffff:ffff",
        "2001:1::4", "2001:10::1", "2001:1ff:ffff:ffff:ffff:ffff:ffff:ffff",
        "64:ff9b:1::a00:1", "64:ff9b:1::5db8:d822", "64:ff9b:1::", "64:ff9b:1:ffff:ffff:ffff:ffff:ffff",
        "3fff::", "3fff:fff:ffff:ffff:ffff:ffff:ffff:ffff", "5f00::1",
        "::ffff:198.18.0.1", "::ffff:0:198.19.255.255", "::198.51.100.1",
        "64:ff9b::198.18.0.1", "2002:c612:1::1",
    ])
    func rejectsNonPublicLiteralAndImageURL(address: String) {
        #expect(ContentSanitizer.isNonPublicAddressLiteral(address))
        if !address.hasPrefix("198.18.") && !address.hasPrefix("198.19.") {
            #expect(ContentSanitizer.isNonPublicResolvedAddress(address))
        }
        let host = address.contains(":") ? "[\(address)]" : address
        #expect(ContentSanitizer.imageURL("https://\(host)/image.png") == nil)
    }

    @Test(arguments: [
        "198.17.255.255", "198.20.0.0", "192.0.1.255", "192.0.3.0",
        "198.51.99.255", "198.51.101.0", "203.0.112.255", "203.0.114.0",
        "192.31.196.1", "192.52.193.1", "192.175.48.1", "93.184.216.34",
        "2001:4860:4860::8888", "2606:4700:4700::1111",
        "2001:1::1", "2001:1::2", "2001:1::3", "2001:3::1", "2001:4:112::1",
        "2001:20::1", "2001:2f:ffff:ffff:ffff:ffff:ffff:ffff",
        "2001:30::1", "2001:3f:ffff:ffff:ffff:ffff:ffff:ffff", "2001:200::1",
        "2001:db7:ffff:ffff:ffff:ffff:ffff:ffff", "2001:db9::1", "3fff:1000::1",
        "64:ff9b::93.184.216.34", "::ffff:93.184.216.34", "2002:5db8:d822::1",
    ])
    func retainsPublicAddressesAndGlobalExceptions(address: String) {
        #expect(!ContentSanitizer.isNonPublicAddressLiteral(address))
        let host = address.contains(":") ? "[\(address)]" : address
        #expect(ContentSanitizer.imageURL("https://\(host)/image.png") != nil)
    }

    // MARK: - Group relay rows
    //
    // #298 — group relay strings come from `AppGroupRecordFfi.relays`, which is
    // MLS-propagated group metadata controlled by a (possibly malicious) group
    // admin. The Relays section in `GroupDetailsView` must strip bidi /
    // zero-width characters so a relay URL can't visually spoof a trusted host
    // (Trojan-Source-style), matching the defense `KeyPackagesView` already
    // applies to relay strings.

    @Test @MainActor func stripsBidiAndZeroWidthFromRelayRows() {
        let rows = GroupRelaysPresentation.rows(for: [
            "wss://relay\u{202E}evil.example",
            "wss://a\u{200B}b.example"
        ])

        #expect(rows.count == 2)
        #expect(!rows.contains { $0.unicodeScalars.contains { $0.value == 0x202E } })
        #expect(!rows.contains { $0.unicodeScalars.contains { $0.value == 0x200B } })
        #expect(rows.contains("wss://relayevil.example"))
        #expect(rows.contains("wss://ab.example"))
    }

    @Test @MainActor func stripsAllBidiAndFormattingControlScalars() {
        // LRM, RLM, LRE..RLO, isolates, ALM, ZWSP, BOM must all be removed.
        let spoofed = "wss://x"
            + "\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}"
            + "\u{2066}\u{2067}\u{2068}\u{2069}\u{061C}\u{200B}\u{FEFF}"
            + ".example"
        let rows = GroupRelaysPresentation.rows(for: [spoofed])

        #expect(rows == ["wss://x.example"])
    }

    /// #306 — relay rows must also strip the invisible format characters the
    /// shared sanitizer preserves for general text: ZWNJ, ZWJ, WORD JOINER.
    @Test @MainActor func stripsResidualInvisibleFormatCharacters() {
        let spoofed = "wss://re\u{200C}lay\u{200D}evil\u{2060}.example"
        let rows = GroupRelaysPresentation.rows(for: [spoofed])
        #expect(rows == ["wss://relayevil.example"])
        #expect(!rows.contains { $0.unicodeScalars.contains { [0x200C, 0x200D, 0x2060].contains($0.value) } })
    }

    @Test @MainActor func emptyRelaysRendersEmptyMessage() {
        #expect(GroupRelaysPresentation.rows(for: []) == [GroupRelaysPresentation.emptyMessage])
    }

    @Test @MainActor func relaysThatSanitizeAwayFallBackToEmptyMessage() {
        // A non-empty input whose every entry collapses to nothing renderable
        // must still show the empty state, never a blank disclosure.
        let rows = GroupRelaysPresentation.rows(for: ["\u{200B}", "\u{FEFF}\u{202E}"])
        #expect(rows == [GroupRelaysPresentation.emptyMessage])
    }

    @Test @MainActor func cleanRelaysPassThroughUnchanged() {
        let clean = ["wss://relay.one.example", "wss://relay.two.example"]
        #expect(GroupRelaysPresentation.rows(for: clean) == clean)
        #expect(GroupRelaysPresentation.summary(for: clean) == LocalizedNumberLabel.decimal(2))
    }

    @Test @MainActor func emptyRelaySummaryMatchesTheDestinationEmptyState() {
        #expect(GroupRelaysPresentation.summary(for: []) == GroupRelaysPresentation.emptyMessage)
        #expect(
            GroupRelaysPresentation.summary(for: ["\u{200B}"])
                == GroupRelaysPresentation.emptyMessage
        )
    }

    @Test @MainActor func collapsesWhitespaceAndTrims() {
        // singleLine collapses internal whitespace runs and trims; verify the
        // group rows inherit that normalization.
        let rows = GroupRelaysPresentation.rows(for: ["  wss://relay\t\n  spaced.example  "])
        #expect(rows == ["wss://relay spaced.example"])
    }

    // MARK: - Published relay list rows
    //
    // #365 — `RelaysView`'s "Published Relay Lists" section renders relay URLs
    // from relay-hosted NIP-65 / kind:10050 inbox events. Those are
    // relay-influenced display strings, so they must be routed through the
    // relay/URL display boundary sanitizer to strip bidi / zero-width /
    // invisible-format characters that could visually spoof a host
    // (Trojan-Source-style), matching the defense `KeyPackagesView.sanitizedRelays`
    // and `GroupRelaysPresentation.rows` already apply (#298 / #306). The
    // "Missing" footer is enum-backed and should render stable local labels.

    @Test @MainActor func stripsBidiAndZeroWidthFromPublishedRows() {
        let rows = RelaySettings.publishedRelayRows([
            "wss://relay\u{202E}evil.example",
            "wss://a\u{200B}b.example"
        ])

        #expect(rows.count == 2)
        #expect(!rows.contains { $0.unicodeScalars.contains { $0.value == 0x202E } })
        #expect(!rows.contains { $0.unicodeScalars.contains { $0.value == 0x200B } })
        #expect(rows.contains("wss://relayevil.example"))
        #expect(rows.contains("wss://ab.example"))
    }

    @Test @MainActor func stripsAllBidiAndFormattingControlScalarsFromPublishedRows() {
        // LRM, RLM, LRE..RLO, isolates, ALM, ZWSP, BOM must all be removed.
        let spoofed = "wss://x"
            + "\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}"
            + "\u{2066}\u{2067}\u{2068}\u{2069}\u{061C}\u{200B}\u{FEFF}"
            + ".example"
        #expect(RelaySettings.publishedRelayRows([spoofed]) == ["wss://x.example"])
    }

    @Test @MainActor func stripsResidualInvisibleFormatCharactersFromPublishedRows() {
        // #306 — ZWNJ, ZWJ, WORD JOINER that the shared sanitizer preserves for
        // general text must still be stripped from relay host strings.
        let spoofed = "wss://re\u{200C}lay\u{200D}evil\u{2060}.example"
        let rows = RelaySettings.publishedRelayRows([spoofed])
        #expect(rows == ["wss://relayevil.example"])
        #expect(!rows.contains { $0.unicodeScalars.contains { [0x200C, 0x200D, 0x2060].contains($0.value) } })
    }

    @Test @MainActor func emptyPublishedListRendersNotPublishedMessage() {
        #expect(RelaySettings.publishedRelayRows([]) == [RelaySettings.notPublishedMessage])
    }

    @Test @MainActor func publishedRowsThatSanitizeAwayFallBackToNotPublishedMessage() {
        // A non-empty input whose every entry collapses to nothing renderable
        // must still show the empty state, never a blank disclosure row.
        let rows = RelaySettings.publishedRelayRows(["\u{200B}", "\u{FEFF}\u{202E}"])
        #expect(rows == [RelaySettings.notPublishedMessage])
    }

    @Test @MainActor func cleanPublishedRowsPassThroughUnchanged() {
        let clean = ["wss://relay.one.example", "wss://relay.two.example"]
        #expect(RelaySettings.publishedRelayRows(clean) == clean)
    }

    @Test @MainActor func collapsesWhitespaceAndTrimsPublishedRows() {
        let rows = RelaySettings.publishedRelayRows(["  wss://relay\t\n  spaced.example  "])
        #expect(rows == ["wss://relay spaced.example"])
    }

    // MARK: - Editable relay rows
    //
    // #467 — the editable account-relays section is the same relay-influenced
    // render surface as the published lists, so it must sanitize identically.
    // It diverges in one way: editableRelayDisplay is strictly 1:1 with its
    // input (delete-by-index alignment) and never drops an entry, so a fully
    // stripped entry falls back to a placeholder instead of vanishing.

    @Test @MainActor func editableRelayDisplayStripsBidiAndZeroWidth() {
        let rlo = RelaySettings.editableRelayDisplay("wss://relay\u{202E}evil.example")
        let zwsp = RelaySettings.editableRelayDisplay("wss://a\u{200B}b.example")

        #expect(rlo == "wss://relayevil.example")
        #expect(zwsp == "wss://ab.example")
        #expect(!rlo.unicodeScalars.contains { $0.value == 0x202E })
        #expect(!zwsp.unicodeScalars.contains { $0.value == 0x200B })
    }

    @Test @MainActor func editableRelayDisplayStripsResidualInvisibleFormat() {
        // #306 — ZWNJ, ZWJ, WORD JOINER the shared sanitizer keeps for general
        // text must still be stripped from a relay host string.
        let spoofed = "wss://re\u{200C}lay\u{200D}evil\u{2060}.example"
        #expect(RelaySettings.editableRelayDisplay(spoofed) == "wss://relayevil.example")
    }

    @Test @MainActor func editableRelayDisplayKeepsCleanUrlUnchanged() {
        #expect(RelaySettings.editableRelayDisplay("wss://relay.example") == "wss://relay.example")
    }

    @Test @MainActor func editableRelayDisplayFallsBackForFullyStrippedEntry() {
        // Diverges from publishedRelayRows (which drops these): an editable row
        // must survive so the user can still delete the junk entry.
        #expect(RelaySettings.editableRelayDisplay("\u{200B}") == RelaySettings.invalidRelayMessage)
        #expect(RelaySettings.editableRelayDisplay("\u{FEFF}\u{202E}") == RelaySettings.invalidRelayMessage)
    }

    // MARK: - Missing relay footer labels

    @Test @MainActor func missingLabelsRenderStableEnumNames() {
        #expect(RelaySettings.missingRelayLabels([.nip65, .inbox]) == ["NIP-65", "Inbox"])
    }

    @Test @MainActor func emptyMissingListYieldsNoLabels() {
        #expect(RelaySettings.missingRelayLabels([]).isEmpty)
    }
}
