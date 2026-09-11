import Foundation
import MarmotKit

nonisolated enum MessageForwardingPolicy {
    /// Forwarding intentionally copies only the original plaintext. It carries
    /// no sender attribution, quote relation, attachment, or forwarded marker.
    static func forwardableText(for record: AppMessageRecordFfi) -> String? {
        switch MessageSemantics.classify(record) {
        case .chat, .reply, .media:
            return record.plaintext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : record.plaintext
        case .streamFinal, .reaction, .delete, .edit, .agentStreamStart,
             .agentActivity, .agentOperation, .groupSystem, .unknown:
            return nil
        }
    }
}

nonisolated enum MessageEditingPolicy {
    static func canEdit(
        _ record: AppMessageRecordFfi,
        isDeleted: Bool,
        canSendMessages: Bool
    ) -> Bool {
        guard canSendMessages,
              !isDeleted,
              !record.messageIdHex.isEmpty,
              record.direction == "sent"
        else { return false }

        switch MessageSemantics.classify(record) {
        case .chat, .reply, .media:
            return true
        case .streamFinal, .reaction, .delete, .edit, .agentStreamStart,
             .agentActivity, .agentOperation, .groupSystem, .unknown:
            return false
        }
    }

    static func normalizedContent(_ content: String) -> String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(ContentSanitizer.maxMessageLength))
    }
}

/// A GIF message is edited through its caption. The envelope's URL and credit
/// line stay out of the composer and are re-attached on save, so an edit cannot
/// expose or mangle the remote media reference.
nonisolated enum GiphyMessageEditProjection {
    static func editableCaption(for plaintext: String) -> String? {
        guard let media = RemoteGiphyMedia.parse(wireText: plaintext) else { return nil }
        return media.caption ?? ""
    }

    /// Nil when the edited caption no longer fits the GIF envelope; refusing
    /// beats truncating the text or dropping the GIF.
    static func editedPlaintext(original: String, caption: String) -> String? {
        guard let media = RemoteGiphyMedia.parse(wireText: original) else { return caption }
        return media.captionedWireText(caption)
    }
}

nonisolated struct MessageDeleteCapability: Equatable, Sendable {
    let canDeleteForMe: Bool
    let canDeleteForEveryone: Bool

    static let unavailable = MessageDeleteCapability(
        canDeleteForMe: false,
        canDeleteForEveryone: false
    )

    var canDelete: Bool {
        canDeleteForMe || canDeleteForEveryone
    }
}

nonisolated enum MessageDeletePolicy {
    /// The single authorization model shared by the actions menu and both
    /// mutation paths. Group-admin status never grants moderation inside a DM.
    static func capability(
        isDirectMessage: Bool,
        isMine: Bool,
        isSelfAdmin: Bool,
        localDeleteSupported: Bool,
        remoteDeleteSupported: Bool,
        isDeleted: Bool,
        isHidden: Bool
    ) -> MessageDeleteCapability {
        guard !isDeleted, !isHidden else { return .unavailable }
        let canModerate = !isDirectMessage && isSelfAdmin
        return MessageDeleteCapability(
            canDeleteForMe: localDeleteSupported,
            canDeleteForEveryone: remoteDeleteSupported && (isMine || canModerate)
        )
    }
}

nonisolated enum MessageDeleteSupportingCopy: Equatable, Sendable {
    case chooseScope
    case localOnly
    case moderation
}

nonisolated enum MessageDeletePresentation {
    static func supportingCopy(
        capability: MessageDeleteCapability,
        isMine: Bool
    ) -> MessageDeleteSupportingCopy {
        if capability.canDeleteForEveryone && !isMine {
            return .moderation
        }
        if capability.canDeleteForEveryone {
            return .chooseScope
        }
        return .localOnly
    }
}

struct MessageForwardDestination: Identifiable, Hashable {
    let id: String
    let title: String
    let avatarURL: URL?
}

nonisolated enum MessageForwardDestinationPresentation {
    @MainActor
    static func destinations(
        from items: [ChatsListViewModel.Item],
        excludingGroupIdHex currentGroupIdHex: String
    ) -> [MessageForwardDestination] {
        sortedDestinations(
            items.compactMap { item in
                guard item.id != currentGroupIdHex,
                      !item.id.isEmpty,
                      !item.row.pendingConfirmation,
                      // Left/removed rows persist in the chat list; a forward
                      // to one fails at send (no membership, no keys).
                      item.isActiveMember
                else { return nil }
                return MessageForwardDestination(
                    id: item.id,
                    title: item.title,
                    avatarURL: item.avatarURL
                )
            }
        )
    }

    static func destinations(
        from rows: [ChatListRowFfi],
        excludingGroupIdHex currentGroupIdHex: String
    ) -> [MessageForwardDestination] {
        var seen = Set<String>()
        return sortedDestinations(rows
            .filter { row in
                row.groupIdHex != currentGroupIdHex
                    && !row.groupIdHex.isEmpty
                    && !row.pendingConfirmation
                    && GroupManagementPresentation.isActiveChatListMember(row.selfMembership)
                    && seen.insert(row.groupIdHex).inserted
            }
            .map { row in
                MessageForwardDestination(
                    id: row.groupIdHex,
                    title: ContentSanitizer.groupName(row.groupName)
                        ?? ContentSanitizer.groupName(row.title)
                        ?? IdentityFormatter.short(row.groupIdHex),
                    avatarURL: ContentSanitizer.imageURL(row.avatarUrl)
                )
            }
        )
    }

    private static func sortedDestinations(
        _ destinations: [MessageForwardDestination]
    ) -> [MessageForwardDestination] {
        destinations.sorted { lhs, rhs in
            let comparison = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
        }
    }
}

struct MessageForwardResult: Equatable {
    let successfulGroupIds: Set<String>
    let failedGroupIds: Set<String>

    var succeededCompletely: Bool {
        !successfulGroupIds.isEmpty && failedGroupIds.isEmpty
    }
}
