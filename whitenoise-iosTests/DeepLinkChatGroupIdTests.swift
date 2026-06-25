import Testing
@testable import whitenoise_ios

/// #68 — chat deep links must carry a 64-char (32-byte) hex group id; any other
/// length must be rejected before it reaches Marmot.
struct DeepLinkChatGroupIdTests {
    private let valid64 = String(repeating: "a", count: 64)

    @Test func acceptsAndLowercases64CharHexGroupId() {
        #expect(DeepLink.parse(string: "\(DeepLink.scheme)://chat/\(valid64)") == .chat(groupIdHex: valid64))
        #expect(DeepLink.parse(string: "\(DeepLink.scheme)://chat/\(valid64.uppercased())") == .chat(groupIdHex: valid64))
    }

    @Test func rejectsNon64CharOrNonHexGroupId() {
        #expect(DeepLink.parse(string: "\(DeepLink.scheme)://chat/abc") == nil)
        #expect(DeepLink.parse(string: "\(DeepLink.scheme)://chat/\(String(repeating: "a", count: 63))") == nil)
        #expect(DeepLink.parse(string: "\(DeepLink.scheme)://chat/\(String(repeating: "a", count: 65))") == nil)
        #expect(DeepLink.parse(string: "\(DeepLink.scheme)://chat/\(String(repeating: "z", count: 64))") == nil)
    }
}
