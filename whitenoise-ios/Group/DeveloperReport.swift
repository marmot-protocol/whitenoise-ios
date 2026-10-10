import Foundation
import MarmotKit

/// What the White Noise team receives when someone reports a user: the
/// reported npub, the reason, and the reporter's own optional explanation.
/// Never the reported message or anything that identifies the conversation.
/// It travels as an ordinary encrypted message in the reporter's support
/// chat, so the reporter can see exactly what was shared.
nonisolated enum DeveloperReportContent {
    enum Kind: Equatable {
        case message(reason: ReportReasonFfi, explanation: String)
        case block
    }

    static let explanationLimit = 1000

    /// Markdown in English on purpose: the team reads it, not the reporter's
    /// locale. The npub sits in a code span so it stays copyable text rather
    /// than rendering as a mention.
    static func text(kind: Kind, reportedAccountIdHex: String) -> String? {
        guard let npub = IdentityPresentation.canonicalNpub(accountIdHex: reportedAccountIdHex) else {
            return nil
        }
        switch kind {
        case .message(let reason, let explanation):
            var fields = [
                "**Reported user:** `\(npub)`",
                "**Reason:** \(reasonName(reason))"
            ]
            let singleLine = bounded(explanation, limit: explanationLimit)
                .split(whereSeparator: \.isNewline)
                .joined(separator: " ")
            if !singleLine.isEmpty {
                fields.append("**Explanation:** \(singleLine)")
            }
            return "**User report**\n\n" + fields.map { "- \($0)" }.joined(separator: "\n")
        case .block:
            return "**Blocked user report**\n\n- **Blocked user:** `\(npub)`"
        }
    }

    static func reasonName(_ reason: ReportReasonFfi) -> String {
        switch reason {
        case .spam: "Spam"
        case .nudity: "Nudity"
        case .malware: "Malware"
        case .profanity: "Profanity"
        case .illegal: "Illegal content"
        case .impersonation: "Impersonation"
        case .other: "Other"
        }
    }

    private static func bounded(_ value: String, limit: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }
}

/// Who may be reported to, or blocked from, a message's long-press menu.
nonisolated enum MessageModerationPolicy {
    /// Someone else's live message with a valid author key. Your own messages
    /// and deleted ones have nothing to report or block.
    static func isOtherAuthor(
        direction: String,
        sender: String,
        myAccountId: String?,
        isDeleted: Bool
    ) -> Bool {
        guard !isDeleted, direction != "sent",
              let author = Hex.normalized32Bytes(sender) else { return false }
        return author != Hex.normalized32Bytes(myAccountId)
    }
}

/// Delivers a report to the White Noise team through the support chat,
/// opening that chat first when this account has none.
@MainActor
enum DeveloperReportSender {
    enum Failure: Error {
        case noActiveAccount
        case supportUnavailable
    }

    static func send(_ text: String, using appState: AppState) async throws {
        guard let accountRef = appState.activeAccountRef else { throw Failure.noActiveAccount }
        guard let recipient = WhiteNoiseSupportContact.recipient else { throw Failure.supportUnavailable }
        let client = try appState.currentMarmotClient()
        let existing = try await client.existingDirectConversation(
            accountRef: accountRef,
            peerAccountId: recipient.accountIdHex.lowercased()
        )
        let outcome = await DirectChatStarter().start(
            accountIdHex: recipient.accountIdHex,
            memberRef: recipient.memberRef,
            existingGroupIdHex: existing?.reusable == true ? existing?.groupIdHex : nil,
            using: appState
        )
        let groupIdHex: String
        switch outcome {
        case .opened(let id), .created(let id):
            groupIdHex = id
        case .failed, .ignored:
            throw Failure.supportUnavailable
        }
        try Task.checkCancellation()
        guard appState.activeAccountRef == accountRef else { throw CancellationError() }
        _ = try await client.sendText(accountRef: accountRef, groupIdHex: groupIdHex, text: text)
    }

    /// The block itself already succeeded, so a failed report surfaces as a
    /// toast rather than undoing or blocking anything.
    static func sendBlockReport(_ text: String, using appState: AppState) async {
        do {
            try await send(text, using: appState)
            appState.present(.success(
                L10n.string("Report submitted"),
                message: L10n.string("Sent to the White Noise team.")
            ))
        } catch is CancellationError {
        } catch {
            appState.present(.error(
                L10n.string("Report not sent"),
                message: failureMessage(for: error)
            ))
        }
    }

    static func failureMessage(for error: Error) -> String {
        if error is Failure {
            return L10n.string("Couldn't reach White Noise. Please check your connection and try again.")
        }
        return UserFacingError.message(for: error)
    }
}
