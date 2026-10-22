import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

@MainActor
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
}
