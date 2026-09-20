import Foundation
import MarmotKit

/// Content identity of one outgoing send, used to bind MDK's own pending
/// projection to the local bubble that produced it.
///
/// MDK commits and projects a locally-sent row *before* `sendMessageDraft`
/// returns that row's message id, so a rendered optimistic bubble can meet its
/// own durable row with no id in hand. The fingerprint is everything MDK
/// preserves verbatim from the submission.
nonisolated struct LocalSendFingerprint: Equatable, Hashable {
    let groupIdHex: String
    let sender: String
    let plaintext: String
    let kind: UInt64
    let replyTargetId: String?
    let isMedia: Bool
}

nonisolated struct LocalSendCandidate: Equatable {
    let rowID: String
    /// Monotonic Send-tap order within this conversation.
    let order: UInt64
    let fingerprint: LocalSendFingerprint
}

nonisolated enum OutgoingSendCorrelation {
    /// The local send an unrecognized own row belongs to.
    ///
    /// Candidates are already filtered to submitted, still-unclaimed sends.
    /// Among fingerprint matches this picks the earliest Send tap, which is the
    /// order MDK committed them (`OutgoingSendQueue` serializes submission per
    /// conversation). The exact id from the send response rebinds
    /// authoritatively afterwards, so two identical back-to-back messages can
    /// at worst swap two rows that render identically — never duplicate or drop
    /// one. Returns nil when nothing matches: the row then renders under its own
    /// message id, which is what a send from another device should do.
    static func claimant(
        for fingerprint: LocalSendFingerprint,
        candidates: [LocalSendCandidate]
    ) -> String? {
        candidates
            .filter { $0.fingerprint == fingerprint }
            .min { lhs, rhs in
                lhs.order == rhs.order ? lhs.rowID < rhs.rowID : lhs.order < rhs.order
            }?
            .rowID
    }
}

// `ConversationViewModel`'s classification statics are MainActor-isolated; the
// matching itself above stays pure and nonisolated.
@MainActor
extension LocalSendFingerprint {
    /// Fingerprint of a locally staged optimistic record. A media send's
    /// optimistic record carries no `imeta` tags (they only exist after the
    /// upload), so staged local attachments are the media discriminator.
    init(optimistic record: AppMessageRecordFfi, hasStagedMedia: Bool) {
        self.init(
            groupIdHex: record.groupIdHex,
            sender: record.sender,
            plaintext: record.plaintext,
            kind: record.kind,
            replyTargetId: ConversationViewModel.replyTargetMessageId(in: record),
            isMedia: hasStagedMedia || ConversationViewModel.isMediaRecord(record)
        )
    }

    /// Fingerprint of a durable row projected by MDK.
    init(projected record: AppMessageRecordFfi, replyTargetId: String?) {
        self.init(
            groupIdHex: record.groupIdHex,
            sender: record.sender,
            plaintext: record.plaintext,
            kind: record.kind,
            replyTargetId: replyTargetId ?? ConversationViewModel.replyTargetMessageId(in: record),
            isMedia: ConversationViewModel.isMediaRecord(record)
        )
    }
}
