import Foundation
import MarmotKit

struct PresentedChatListCursor: Equatable {
    private var generation: String?
    private var sequence: UInt64 = 0
    private var storeEpoch: Data?

    init() {}
    init(initial: PresentedChatListUpdateFfi) {
        generation = initial.subscriptionGeneration
        sequence = initial.sequence
        storeEpoch = initial.snapshot.presentationVersion.accountStoreEpoch
    }

    func requiresReopen(_ update: PresentedChatListUpdateFfi) -> Bool {
        update.subscriptionGeneration != generation
            || update.snapshot.presentationVersion.accountStoreEpoch != storeEpoch
    }

    mutating func accept(_ update: PresentedChatListUpdateFfi) -> Bool {
        guard update.subscriptionGeneration == generation, update.sequence > sequence,
              !requiresReopen(update) else { return false }
        sequence = update.sequence
        return true
    }
}

@MainActor
enum SelectedChatPresentation {
    static func display(
        _ selected: ConversationPresentationFfi,
        row: ChatListRowFfi,
        nickname: String? = nil
    ) -> ChatsListViewModel.Display {
        let title: String
        switch selected.title {
        case .literal(let text):
            let localTitle = row.conversationKind == .direct && selected.peerId != nil
                ? ContentSanitizer.displayName(nickname)
                : nil
            title = localTitle ?? ContentSanitizer.groupName(text) ?? L10n.string("Unnamed group")
        case .unnamedGroup:
            title = L10n.string("Unnamed group")
        case .unavailableConversation:
            title = L10n.string("Conversation unavailable")
        }
        let avatarURL: URL?
        if case .remoteImage(let url, _) = selected.avatar {
            avatarURL = ContentSanitizer.imageURL(url)
        } else {
            avatarURL = nil
        }
        return ChatsListViewModel.Display(
            title: title, avatarURL: avatarURL, avatarSeed: avatarSeed(for: selected),
            isDirectMessage: row.conversationKind == .direct,
            directPeerAccountIdHex: selected.peerId
        )
    }

    static func avatarSeed(for selected: ConversationPresentationFfi) -> String {
        // Match profile/member colors without replacing MDK's selected avatar or cache key.
        if selected.avatarSource == .peerProfile || selected.avatarSource == .peerFallback,
           let peerId = selected.peerId {
            return peerId
        }
        switch selected.avatar {
        case .remoteImage(_, let seed), .encryptedGroupImage(_, let seed), .placeholder(let seed, _):
            return seed
        }
    }
}
