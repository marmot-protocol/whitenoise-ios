import Foundation
import MarmotKit

nonisolated enum OutgoingSendSizeRejection: Equatable, Sendable {
    case attachments(Set<UUID>)
    case unidentifiedAttachment
    case text
}

nonisolated enum OutgoingSendPhase {
    case upload(candidates: [MediaDraftAttachment])
    case admission
}

nonisolated enum OutgoingSendSizePolicy {
    static func sendLimit(for attachment: MediaDraftAttachment) -> Int {
        attachment.kind == .image
            ? MediaDraftProcessor.maxImageAttachmentBytes
            : MediaDraftProcessor.maxAttachmentBytes
    }

    static func oversizedAttachmentIDs(in attachments: [MediaDraftAttachment]) -> Set<UUID> {
        Set(attachments.filter { $0.data.count > sendLimit(for: $0) }.map(\.id))
    }

    static func rejection(for error: Error, phase: OutgoingSendPhase) -> OutgoingSendSizeRejection? {
        switch phase {
        case .upload(let candidates):
            let oversized = oversizedAttachmentIDs(in: candidates)
            if !oversized.isEmpty { return .attachments(oversized) }
            guard isSizeRejection(error) else { return nil }
            if candidates.count == 1, let only = candidates.first { return .attachments([only.id]) }
            return .unidentifiedAttachment
        case .admission:
            return isSizeRejection(error) ? .text : nil
        }
    }

    static func isSizeRejection(_ error: Error) -> Bool {
        if let failure = error as? MediaDraftProcessor.Failure, case .attachmentTooLarge = failure {
            return true
        }
        guard error is MarmotKitError else { return false }
        let diagnostic = UserFacingError.sanitizedDiagnostic(for: error).lowercased()
        return sizeRejectionMarkers.contains { diagnostic.contains($0) }
    }

    private static let sizeRejectionMarkers = [
        "http 413", "too large", "too big",
        "message too long", "content too long", "text too long",
    ]
}

nonisolated struct ConversationComposerContents: Equatable {
    var draft: String
    var mediaDrafts: [MediaDraftAttachment]
    var replyTargetMessageIdHex: String?

    var isEmpty: Bool {
        draft.isEmpty && mediaDrafts.isEmpty && replyTargetMessageIdHex == nil
    }
}

nonisolated enum ConversationSendRecovery {
    static func restoredContents(
        after rejection: OutgoingSendSizeRejection,
        tapped: ConversationComposerContents,
        current: ConversationComposerContents,
        isEditing: Bool
    ) -> ConversationComposerContents? {
        guard current.isEmpty, !isEditing else { return nil }
        var restored = tapped
        if case .attachments(let removed) = rejection {
            restored.mediaDrafts.removeAll { removed.contains($0.id) }
        }
        return restored.draft.isEmpty && restored.mediaDrafts.isEmpty ? nil : restored
    }

    static func notice(for rejection: OutgoingSendSizeRejection, restored: Bool) -> (title: String, message: String) {
        let title = rejection == .text
            ? L10n.string("Message too long")
            : L10n.string("Attachment too large")
        guard restored else {
            return (title, L10n.string("Your message was kept in the failed bubble."))
        }
        switch rejection {
        case .attachments:
            return (title, L10n.string("The attachment was removed. The rest of your message is back in the composer."))
        case .unidentifiedAttachment:
            return (title, L10n.string("Remove the attachment that is too large for the media server, then send again."))
        case .text:
            return (title, L10n.string("Shorten your message, then send again."))
        }
    }
}
