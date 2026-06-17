import Testing
import Foundation
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
}
