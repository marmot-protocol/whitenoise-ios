import SwiftUI
import MarmotKit

/// MDK's advisory refusals of a group change (invite, remove, admin, profile,
/// image, retention, disbanding). Messages and leaving are never refused.
/// After the user accepts the risk, one acknowledgement admits one attempt,
/// so the host acknowledges and retries the same change.
nonisolated enum GroupChangeAdvisory: Hashable, Sendable {
    /// History recovery covers this device's epoch: the group may have moved on,
    /// and a change from here could split it (mdk#2258).
    case catchingUp
    /// The group's last change is still owed to one of its relays (mdk#2255).
    case commitUndelivered

    init?(error: Error) {
        switch error as? MarmotKitError {
        case .GroupCatchingUp: self = .catchingUp
        case .GroupCommitUndelivered: self = .commitUndelivered
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .catchingUp: L10n.string("This chat may be out of date")
        case .commitUndelivered: L10n.string("Last group change not delivered")
        }
    }

    /// Invites get the strongest wording: an invite onto a branch that loses
    /// leaves the new member with an invitation that no longer works.
    func message(isInvite: Bool) -> String {
        switch (self, isInvite) {
        case (.catchingUp, false):
            L10n.string("This device may not have the group's latest changes yet. Changing the group now could split it for everyone. Wait for it to sync, or continue anyway?")
        case (.catchingUp, true):
            L10n.string("This device may not have the group's latest changes yet. Inviting now could split the group for everyone and leave the people you invite with an invitation that no longer works. Wait for it to sync, or continue anyway?")
        case (.commitUndelivered, _):
            L10n.string("The group's last change hasn't reached all of its relays yet. Members who use only those relays may not be able to follow this change. Wait, or continue anyway?")
        }
    }

    var declinedMessage: String {
        switch self {
        case .catchingUp: L10n.string("Group not changed. Try again once this chat has synced.")
        case .commitUndelivered: L10n.string("Group not changed. Try again once the last change has reached every relay.")
        }
    }
}

/// The user chose to wait rather than accept an advisory refusal.
nonisolated struct GroupChangeAdvisoryDeclined: LocalizedError, Equatable {
    let advisory: GroupChangeAdvisory
    var errorDescription: String? { advisory.declinedMessage }
}

enum GroupChangeAdvisoryRetry {
    /// Runs `change`; after an advisory refusal, asks for consent, acknowledges and
    /// retries. A change can need both acknowledgements, and each kind is asked at
    /// most once per call, so a refusal that recurs after its acknowledgement is thrown.
    static func perform<Result>(
        _ change: () async throws -> Result,
        consent: (GroupChangeAdvisory) async -> Bool,
        acknowledge: (GroupChangeAdvisory) async throws -> Void
    ) async throws -> Result {
        var acknowledged: Set<GroupChangeAdvisory> = []
        while true {
            do {
                return try await change()
            } catch {
                guard let advisory = GroupChangeAdvisory(error: error),
                      !acknowledged.contains(advisory) else { throw error }
                guard await consent(advisory) else { throw GroupChangeAdvisoryDeclined(advisory: advisory) }
                try Task.checkCancellation()
                try await acknowledge(advisory)
                acknowledged.insert(advisory)
            }
        }
    }

    /// Every attempt and acknowledgement takes the live runtime from `client`, so a
    /// consented retry after a runtime restart runs where it was acknowledged.
    static func perform<Result>(
        prompter: GroupChangeAdvisoryPrompter,
        isInvite: Bool = false,
        client: () throws -> MarmotClient,
        accountRef: String,
        groupIdHex: String,
        _ change: (MarmotClient) async throws -> Result
    ) async throws -> Result {
        try await perform({ try await change(client()) }, consent: { advisory in
            await prompter.requestConsent(for: advisory, isInvite: isInvite)
        }, acknowledge: { advisory in
            _ = try await client().acknowledgeGroupChangeAdvisory(
                advisory, accountRef: accountRef, groupIdHex: groupIdHex
            )
        })
    }
}

/// Holds the one pending consent request; `groupChangeAdvisoryAlert` renders it.
@MainActor
@Observable
final class GroupChangeAdvisoryPrompter {
    struct Prompt: Identifiable, Equatable {
        let id = UUID()
        let advisory: GroupChangeAdvisory
        let isInvite: Bool
        var title: String { advisory.title }
        var message: String { advisory.message(isInvite: isInvite) }
    }

    private(set) var prompt: Prompt?
    @ObservationIgnored private var continuation: CheckedContinuation<Bool, Never>?

    func requestConsent(for advisory: GroupChangeAdvisory, isInvite: Bool) async -> Bool {
        // A newer request never strands an older waiter.
        if let prompt { resolve(id: prompt.id, approved: false) }
        let prompt = Prompt(advisory: advisory, isInvite: isInvite)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                self.prompt = prompt
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolve(id: prompt.id, approved: false) }
        }
    }

    /// Resolves only the prompt it was shown for, so a late dismissal of one
    /// alert cannot answer the next.
    func resolve(id: Prompt.ID, approved: Bool) {
        guard prompt?.id == id, let continuation else { return }
        self.continuation = nil
        prompt = nil
        continuation.resume(returning: approved)
    }

    func cancelPending() {
        if let prompt { resolve(id: prompt.id, approved: false) }
    }
}

extension View {
    /// Attach to whichever view is on top when the change runs: the details
    /// screen, or the sheet that submitted the change.
    func groupChangeAdvisoryAlert(_ prompter: GroupChangeAdvisoryPrompter, isEnabled: Bool = true) -> some View {
        modifier(GroupChangeAdvisoryAlertModifier(prompter: prompter, isEnabled: isEnabled))
    }
}

private struct GroupChangeAdvisoryAlertModifier: ViewModifier {
    let prompter: GroupChangeAdvisoryPrompter
    let isEnabled: Bool

    func body(content: Content) -> some View {
        let prompt = isEnabled ? prompter.prompt : nil
        content.alert(
            prompt?.title ?? "",
            isPresented: Binding(
                get: { prompt != nil },
                set: { presented in
                    // Buttons resolve first; this only covers a dismissal without one.
                    guard !presented, let id = prompt?.id else { return }
                    Task { @MainActor in prompter.resolve(id: id, approved: false) }
                }
            ),
            presenting: prompt
        ) { prompt in
            Button(L10n.string("Continue anyway"), role: .destructive) {
                prompter.resolve(id: prompt.id, approved: true)
            }
            Button(L10n.string("Wait"), role: .cancel) {
                prompter.resolve(id: prompt.id, approved: false)
            }
        } message: { prompt in
            Text(prompt.message)
        }
    }
}
