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
        update.subscriptionGeneration == generation
            && update.snapshot.presentationVersion.accountStoreEpoch != storeEpoch
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
    static func display(_ selected: ConversationPresentationFfi, row: ChatListRowFfi) -> ChatsListViewModel.Display {
        let title: String
        switch selected.title {
        case .literal(let text):
            title = ContentSanitizer.groupName(text) ?? L10n.string("Unnamed group")
        case .unnamedGroup:
            title = L10n.string("Unnamed group")
        case .unavailableConversation:
            title = L10n.string("Conversation unavailable")
        }
        let avatarURL: URL?
        let seed: String
        switch selected.avatar {
        case .remoteImage(let url, let cacheKey):
            avatarURL = ContentSanitizer.imageURL(url)
            seed = cacheKey
        case .encryptedGroupImage(_, let cacheKey):
            avatarURL = nil
            seed = cacheKey
        case .placeholder(let stableSeed, _):
            avatarURL = nil
            seed = stableSeed
        }
        return ChatsListViewModel.Display(
            title: title, avatarURL: avatarURL, avatarSeed: seed,
            isDirectMessage: row.conversationKind == .direct,
            directPeerAccountIdHex: selected.peerId
        )
    }
}
