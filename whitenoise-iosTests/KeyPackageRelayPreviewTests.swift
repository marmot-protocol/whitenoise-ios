import Testing
import Foundation
import MarmotKit
@testable import whitenoise_ios

/// #53 — the key-package relay preview must strip bidi / zero-width characters,
/// not just C0/DEL, so relay URLs can't be visually spoofed.
@MainActor
struct KeyPackageRelayPreviewTests {

    @Test func stripsBidiAndZeroWidthFromRelayPreview() {
        let preview = KeyPackagesView.sanitizedRelays([
            "wss://relay\u{202E}evil.example",
            "wss://a\u{200B}b.example"
        ])
        #expect(!preview.unicodeScalars.contains { $0.value == 0x202E })
        #expect(!preview.unicodeScalars.contains { $0.value == 0x200B })
        #expect(preview.contains("wss://relayevil.example"))
        #expect(preview.contains("wss://ab.example"))
    }

    /// #306 — the preview must also strip the invisible format characters the
    /// shared sanitizer preserves for general text: ZWNJ, ZWJ, WORD JOINER.
    @Test func stripsResidualInvisibleFormatCharactersFromRelayPreview() {
        let preview = KeyPackagesView.sanitizedRelays([
            "wss://re\u{200C}lay\u{200D}evil\u{2060}.example"
        ])
        #expect(preview == "wss://relayevil.example")
        #expect(!preview.unicodeScalars.contains { [0x200C, 0x200D, 0x2060].contains($0.value) })
    }

    @Test func limitsToFourRelays() {
        let many = (0..<10).map { "wss://r\($0).example" }
        #expect(KeyPackagesView.sanitizedRelays(many).components(separatedBy: ", ").count == 4)
    }

    /// #252 — relay-influenced numeric fields must clamp at the display boundary.
    /// `Int64(bytes)` traps on hostile values near `UInt64.max`; clamping must
    /// not crash and must match `ByteCountFormatter` on the clamped bound.
    @Test func byteCountClampsHostileSizeWithoutTrapping() {
        let hostile = KeyPackagesView.byteCount(UInt64.max)
        let expected = ByteCountFormatter.string(fromByteCount: Int64.max, countStyle: .file)
        #expect(hostile == expected)
        // A normal value is unaffected by clamping.
        #expect(KeyPackagesView.byteCount(1_536)
            == ByteCountFormatter.string(fromByteCount: 1_536, countStyle: .file))
    }

    @Test func publishedDescriptionClampsHostileTimestampWithoutTrapping() {
        // Must not trap on a hostile far-future timestamp near UInt64.max.
        #expect(KeyPackagesView.publishedDescription(UInt64.max) != nil)
        // Zero/empty timestamps render nothing.
        #expect(KeyPackagesView.publishedDescription(0) == nil)
    }

    @Test func currentPackageUsesLifecycleReferenceInsteadOfNewestTimestamp() {
        let current = package(eventId: "current", publishedAt: 10, local: true, relay: true)
        let other = package(eventId: "other", publishedAt: 100, local: false, relay: true)
        let presentation = KeyPackagesPresentation(
            packages: [other, current],
            currentReference: current.keyPackageRefHex,
            currentEventID: current.eventIdHex
        )
        #expect(presentation.current?.identifier == "current")
        #expect(presentation.current?.bytes == 32)
        #expect(presentation.otherRelayPackages.map(\.eventIdHex) == ["other"])
    }

    @Test func normalCurrentPackageHasNoAdditionalRelaySection() {
        let current = package(local: true, relay: true)
        let presentation = KeyPackagesPresentation(
            packages: [current],
            currentReference: current.keyPackageRefHex,
            currentEventID: current.eventIdHex
        )
        #expect(presentation.current != nil)
        #expect(presentation.otherRelayPackages.isEmpty)
    }

    @Test func additionalPackagesRequireRelayEvidenceRegardlessOfLocalOwnership() {
        let local = package(eventId: "local", local: true, relay: false)
        let unclassified = package(eventId: "unknown", local: false, relay: false)
        let retained = package(eventId: "retained", local: true, relay: true)
        let remote = package(eventId: "remote", publishedAt: 10, local: false, relay: true)
        let presentation = KeyPackagesPresentation(
            packages: [local, unclassified, retained, remote, remote],
            currentReference: "current-ref",
            currentEventID: "current-event"
        )
        #expect(presentation.otherRelayPackages.map(\.eventIdHex) == ["remote", "retained"])
    }

    @Test func relayCopiesOfCurrentMaterialAreNotOtherPackages() {
        let current = package(local: true, relay: true)
        var echo = current
        echo.eventIdHex = "different-event"
        echo.local = false
        let presentation = KeyPackagesPresentation(
            packages: [current, echo],
            currentReference: current.keyPackageRefHex,
            currentEventID: current.eventIdHex
        )
        #expect(presentation.otherRelayPackages.isEmpty)
    }

    @Test func lifecycleCurrentPackageRemainsVisibleWhenInventoryMissesIt() {
        let presentation = KeyPackagesPresentation(
            packages: [], currentReference: "reference", currentEventID: "event", publishedAt: 123
        )
        #expect(presentation.current?.identifier == "event")
        #expect(presentation.current?.publishedAt == 123)
        #expect(presentation.current?.bytes == nil)
    }

    @Test func missingLifecycleNeverPromotesAnArbitraryLocalOrRelayPackage() {
        let presentation = KeyPackagesPresentation(
            packages: [package(local: true, relay: true)],
            currentReference: nil, currentEventID: nil
        )
        #expect(presentation.current == nil)
        #expect(presentation.otherRelayPackages.count == 1)
    }

    @Test func absentAuthoredEventCanUseMatchingReference() {
        let current = package(local: true, relay: false)
        let presentation = KeyPackagesPresentation(
            packages: [current], currentReference: current.keyPackageRefHex, currentEventID: nil
        )
        #expect(presentation.current?.identifier == current.eventIdHex)
        #expect(presentation.current?.bytes == 32)
    }

    @Test func newLifecycleEventDoesNotBorrowOldPublicationDetails() {
        let old = package(local: true, relay: true)
        let presentation = KeyPackagesPresentation(
            packages: [old], currentReference: old.keyPackageRefHex,
            currentEventID: "new-event", publishedAt: 55
        )
        #expect(presentation.current?.identifier == "new-event")
        #expect(presentation.current?.publishedAt == 55)
        #expect(presentation.current?.bytes == nil)
        #expect(presentation.otherRelayPackages.isEmpty)
    }

    private func package(
        eventId: String = "event",
        publishedAt: UInt64 = 1,
        local: Bool,
        relay: Bool
    ) -> AccountKeyPackageFfi {
        AccountKeyPackageFfi(
            accountRef: nil,
            accountIdHex: "account",
            keyPackageId: "keyPackageId-\(eventId)",
            keyPackageRefHex: "keyPackageRef-\(eventId)",
            eventIdHex: eventId,
            publishedAt: publishedAt,
            keyPackageBytes: 32,
            sourceRelays: relay ? ["wss://relay.example"] : [],
            local: local,
            relay: relay
        )
    }
}
