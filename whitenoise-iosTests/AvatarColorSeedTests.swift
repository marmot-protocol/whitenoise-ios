import MarmotKit
import Testing
@testable import whitenoise_ios

@MainActor
struct AvatarColorSeedTests {
    @Test(arguments: [PresentationSourceFfi.peerProfile, .peerFallback])
    func personColorMatchesTheirPublicKeyBeforeAndAfterPhotoChanges(source: PresentationSourceFfi) {
        let peer = String(repeating: "ab", count: 32)
        var selected = presentation(source: source, peer: peer)
        #expect(SelectedChatPresentation.avatarSeed(for: selected) == peer)

        selected.avatar = .remoteImage(url: "https://example.com/avatar.jpg", cacheKey: "photo-v1")
        #expect(SelectedChatPresentation.avatarSeed(for: selected) == peer)
        selected.avatar = .remoteImage(url: "https://example.com/new-avatar.jpg", cacheKey: "photo-v2")
        #expect(SelectedChatPresentation.avatarSeed(for: selected) == peer)
    }

    @Test(arguments: [PresentationSourceFfi.group, .groupFallback, .unknownFallback])
    func groupAndUnknownSelectionsKeepTheirOwnSeedEvenWithAPeer(source: PresentationSourceFfi) {
        let selected = presentation(source: source, peer: String(repeating: "ab", count: 32))
        #expect(SelectedChatPresentation.avatarSeed(for: selected) == "selected-seed")
    }

    @Test func unresolvedPeerKeepsTheSelectedFallback() {
        let selected = presentation(source: .peerFallback, peer: nil)
        #expect(SelectedChatPresentation.avatarSeed(for: selected) == "selected-seed")
    }

    private func presentation(source: PresentationSourceFfi, peer: String?) -> ConversationPresentationFfi {
        ConversationPresentationFfi(
            title: .literal(text: "Avatar"),
            avatar: .placeholder(stableSeed: "selected-seed", source: source),
            titleSource: source, avatarSource: source, peerId: peer, resolution: .lastKnown
        )
    }
}
