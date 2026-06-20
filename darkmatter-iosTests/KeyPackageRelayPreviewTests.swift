import Testing
import Foundation
import MarmotKit
@testable import darkmatter_ios

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

    @Test func unclassifiedPackagesRemainVisibleAndManageable() {
        let local = package(eventId: "local", publishedAt: 10, local: true, relay: false)
        let relay = package(eventId: "relay", publishedAt: 20, local: false, relay: true)
        let unclassified = package(eventId: "unclassified", publishedAt: 30, local: false, relay: false)

        let sections = KeyPackagesView.packageSections(for: [local, relay, unclassified])

        #expect(sections.local.map(\.eventIdHex) == ["local"])
        #expect(sections.relayOnly.map(\.eventIdHex) == ["relay"])
        #expect(sections.unclassified.map(\.eventIdHex) == ["unclassified"])
        #expect(sections.visiblePackageCount == 3)
        #expect(!sections.isEmpty)
    }

    @Test func emptyStateOnlyShowsWhenPartitionHasNoPackages() {
        #expect(KeyPackagesView.packageSections(for: []).isEmpty)

        let unclassified = package(eventId: "orphan", local: false, relay: false)
        #expect(!KeyPackagesView.packageSections(for: [unclassified]).isEmpty)
    }

    @Test func badgeTitleMatchesEachFlagCombination() {
        #expect(KeyPackagesView.sourceBadgeTitle(for: package(local: true, relay: true)) == "Synced")
        #expect(KeyPackagesView.sourceBadgeTitle(for: package(local: true, relay: false)) == "Local only")
        #expect(KeyPackagesView.sourceBadgeTitle(for: package(local: false, relay: true)) == "Relay only")
        #expect(KeyPackagesView.sourceBadgeTitle(for: package(local: false, relay: false)) == "Unclassified")
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
