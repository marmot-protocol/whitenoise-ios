import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

@MainActor
struct ConversationInviteActionTests {
    @Test func acceptClearsPendingStateInPlace() async throws {
        let appState = AppState.test()
        appState.activeAccountRef = "account-ref"
        let pending = group(
            name: "invited",
            pendingConfirmation: true,
            welcomerAccountIdHex: hex("44")
        )
        var receivedArguments: (String, String)?
        let viewModel = ConversationViewModel(
            appState: appState,
            group: pending,
            groupCalls: groupCalls(accept: { accountRef, groupIdHex in
                receivedArguments = (accountRef, groupIdHex)
                return group(name: "invited", id: groupIdHex)
            })
        )

        let updated = await viewModel.acceptInvite()

        #expect(receivedArguments?.0 == "account-ref")
        #expect(receivedArguments?.1 == pending.groupIdHex)
        #expect(updated?.pendingConfirmation == false)
        #expect(!viewModel.hasPendingInvite)
        #expect(viewModel.inviteActionInFlight == nil)
    }

    @Test func declineAppliesArchivedInactiveGroup() async throws {
        let appState = AppState.test()
        appState.activeAccountRef = "account-ref"
        let pending = group(name: "invited", pendingConfirmation: true)
        let declined = group(
            name: "invited",
            id: pending.groupIdHex,
            archived: true,
            selfMembership: .left
        )
        var calls: [String] = []
        let viewModel = ConversationViewModel(
            appState: appState,
            group: pending,
            inviteDeclineCalls: inviteDeclineCalls(log: { calls.append($0) }, pending: pending, declined: declined)
        )

        let updated = await viewModel.declineInvite()

        #expect(calls == ["decline account-ref \(pending.groupIdHex)"])
        #expect(updated == declined)
        #expect(viewModel.group == declined)
        #expect(!viewModel.hasPendingInvite)
        #expect(!viewModel.canSendMessages)
        #expect(viewModel.inviteActionInFlight == nil)
    }

    @Test func adminInviteeStepsDownBeforeDeclining() async throws {
        let appState = AppState.test()
        appState.activeAccountRef = "account-ref"
        let pending = group(name: "invited", pendingConfirmation: true)
        let declined = group(name: "invited", id: pending.groupIdHex, archived: true, selfMembership: .left)
        var calls: [String] = []
        let viewModel = ConversationViewModel(
            appState: appState,
            group: pending,
            inviteDeclineCalls: inviteDeclineCalls(log: { calls.append($0) }, pending: pending, declined: declined)
        )

        let updated = await viewModel.declineInvite(steppingDown: true)

        #expect(calls == [
            "selfDemote account-ref \(pending.groupIdHex)",
            "decline account-ref \(pending.groupIdHex)"
        ])
        #expect(updated == declined)
        #expect(!viewModel.hasPendingInvite)
        #expect(viewModel.inviteActionInFlight == nil)
    }

    @Test func failedStepDownLeavesTheInvitationPending() async throws {
        let appState = AppState.test()
        appState.activeAccountRef = "account-ref"
        let pending = group(name: "invited", pendingConfirmation: true)
        var calls: [String] = []
        let viewModel = ConversationViewModel(
            appState: appState,
            group: pending,
            inviteDeclineCalls: inviteDeclineCalls(
                log: { calls.append($0) },
                pending: pending,
                declined: pending,
                selfDemoteError: MarmotKitError.AdminCannotSelfRemove(groupIdHex: pending.groupIdHex)
            )
        )

        let updated = await viewModel.declineInvite(steppingDown: true)

        #expect(calls == ["selfDemote account-ref \(pending.groupIdHex)"])
        #expect(updated == nil)
        #expect(viewModel.hasPendingInvite)
        #expect(viewModel.inviteActionInFlight == nil)
    }

    @Test(arguments: [false, true])
    func choosingWaitWarnsButLeavingTheInviteBarStaysQuiet(leftTheInviteBar: Bool) async throws {
        let appState = AppState.test()
        appState.activeAccountRef = "account-ref"
        let pending = group(name: "invited", pendingConfirmation: true)
        var calls: [String] = []
        let viewModel = ConversationViewModel(
            appState: appState,
            group: pending,
            inviteDeclineCalls: inviteDeclineCalls(
                log: { calls.append($0) },
                pending: pending,
                declined: pending,
                selfDemoteError: GroupChangeAdvisoryDeclined(advisory: .catchingUp)
            )
        )

        let updated = await Task { @MainActor in
            if leftTheInviteBar { withUnsafeCurrentTask { $0?.cancel() } }
            return await viewModel.declineInvite(steppingDown: true)
        }.value

        #expect(calls == ["selfDemote account-ref \(pending.groupIdHex)"])
        #expect(updated == nil)
        #expect(viewModel.hasPendingInvite)
        if leftTheInviteBar {
            #expect(appState.activeToast == nil)
        } else {
            #expect(appState.activeToast?.title == GroupChangeAdvisory.catchingUp.declinedMessage)
        }
    }

    @Test func declineAfterAStepDownThatOutlivedAFailedDeclineNeedsNoSecondStepDown() async throws {
        let appState = AppState.test()
        appState.activeAccountRef = "account-ref"
        let pending = group(name: "invited", pendingConfirmation: true)
        var calls: [String] = []
        let viewModel = ConversationViewModel(
            appState: appState,
            group: pending,
            inviteDeclineCalls: inviteDeclineCalls(
                log: { calls.append($0) },
                pending: pending,
                declined: pending,
                declineError: MarmotKitError.AccountWorkerBusy
            )
        )
        // The open window still says admin until its next update.
        var staleWindow = conversationWindowSnapshot(groupIdHex: pending.groupIdHex)
        staleWindow.pendingConfirmation = true
        staleWindow.header.capabilities.isLastAdmin = false
        staleWindow.header.capabilities.requiresSelfDemoteBeforeLeave = true
        viewModel.installConversationWindow(staleWindow)

        let updated = await viewModel.declineInvite(steppingDown: true)

        #expect(calls == [
            "selfDemote account-ref \(pending.groupIdHex)",
            "decline account-ref \(pending.groupIdHex)"
        ])
        #expect(updated == nil)
        #expect(viewModel.hasPendingInvite)
        #expect(await viewModel.prepareInviteDecline() == .decline)
    }

    @Test func declinePlanFallsBackToTheWindowWhenTheAdminStateCantBeRead() async throws {
        let appState = AppState.test()
        appState.activeAccountRef = "account-ref"
        let pending = group(name: "invited", pendingConfirmation: true)
        var snapshot = conversationWindowSnapshot(groupIdHex: pending.groupIdHex)
        snapshot.pendingConfirmation = true
        snapshot.header.capabilities.isLastAdmin = false
        snapshot.header.capabilities.requiresSelfDemoteBeforeLeave = true
        let viewModel = ConversationViewModel(appState: appState, group: pending)
        viewModel.installConversationWindow(snapshot)

        // AppState.test() has no runtime, so the management read fails.
        #expect(await viewModel.prepareInviteDecline() == .stepDownFirst)
        #expect(viewModel.inviteActionInFlight == nil)
    }

    /// Accepts through `accept`. A group re-read answers with `refreshed`'s
    /// group, or fails when the test gives none.
    private func groupCalls(
        accept: @escaping @MainActor (String, String) async throws -> AppGroupRecordFfi,
        refreshed: (@MainActor () -> AppGroupRecordFfi)? = nil,
        snapshotArguments: (@MainActor (String, String) -> Void)? = nil
    ) -> ConversationGroupCalls {
        ConversationGroupCalls(
            acceptInvite: { _, accountRef, groupIdHex in try await accept(accountRef, groupIdHex) },
            conversationSnapshot: { _, accountRef, groupIdHex in
                snapshotArguments?(accountRef, groupIdHex)
                guard let refreshed else { throw CancellationError() }
                return GroupConversationSnapshotFfi(
                    details: GroupDetailsFfi(group: refreshed(), members: []),
                    managementState: managementState(isSelfAdmin: false, isLastAdmin: false)
                )
            }
        )
    }

    /// The step-down leaves the invitation pending with admin status removed;
    /// only the decline ends it.
    private func inviteDeclineCalls(
        log: @escaping @MainActor (String) -> Void,
        pending: AppGroupRecordFfi,
        declined: AppGroupRecordFfi,
        selfDemoteError: Error? = nil,
        declineError: Error? = nil
    ) -> InviteDeclineCalls {
        InviteDeclineCalls(
            selfDemote: { _, _, accountRef, groupIdHex in
                log("selfDemote \(accountRef) \(groupIdHex)")
                if let selfDemoteError { throw selfDemoteError }
                return GroupMutationResultFfi(
                    summary: SendSummaryFfi(published: 1, messageIds: []),
                    details: GroupDetailsFfi(group: pending, members: []),
                    managementState: managementState(isSelfAdmin: false, isLastAdmin: false)
                )
            },
            decline: { _, accountRef, groupIdHex in
                log("decline \(accountRef) \(groupIdHex)")
                if let declineError { throw declineError }
                return GroupInviteDeclineResultFfi(group: declined, summary: SendSummaryFfi(published: 1, messageIds: []))
            }
        )
    }

    @Test func acceptRetriesOnceWhenWorkerIsDefinitelyBusy() async throws {
        let appState = AppState.test()
        appState.activeAccountRef = "account-ref"
        let pending = group(name: "invited", pendingConfirmation: true)
        var attempts = 0
        var refreshes = 0
        let viewModel = ConversationViewModel(
            appState: appState,
            group: pending,
            groupCalls: groupCalls(
                accept: { _, groupIdHex in
                    attempts += 1
                    if attempts == 1 {
                        throw MarmotKitError.AccountWorkerBusy
                    }
                    return group(name: "invited", id: groupIdHex)
                },
                refreshed: {
                    refreshes += 1
                    return pending
                }
            )
        )

        let updated = await viewModel.acceptInvite()

        #expect(attempts == 2)
        #expect(refreshes == 1)
        #expect(updated?.pendingConfirmation == false)
        #expect(!viewModel.hasPendingInvite)
    }

    @Test func acceptTimeoutRefreshesStateWithoutRetryingAmbiguousOperation() async throws {
        let appState = AppState.test()
        appState.activeAccountRef = "account-ref"
        let pending = group(name: "invited", pendingConfirmation: true)
        var attempts = 0
        let viewModel = ConversationViewModel(
            appState: appState,
            group: pending,
            groupCalls: groupCalls(
                accept: { _, _ in
                    attempts += 1
                    throw MarmotKitError.AccountWorkerResponseTimedOut
                },
                refreshed: { group(name: "invited", id: pending.groupIdHex) }
            )
        )

        let updated = await viewModel.acceptInvite()

        #expect(attempts == 1)
        #expect(updated?.pendingConfirmation == false)
        #expect(!viewModel.hasPendingInvite)
    }

    @Test func staleAcceptRefreshesTheTerminalGroupWithoutRetrying() async throws {
        let appState = AppState.test()
        appState.activeAccountRef = "account-ref"
        let pending = group(name: "invited", pendingConfirmation: true)
        let terminal = group(
            name: "invited",
            id: pending.groupIdHex,
            archived: true,
            selfMembership: .left
        )
        var snapshotArguments: (String, String)?
        var attempts = 0
        let viewModel = ConversationViewModel(
            appState: appState,
            group: pending,
            groupCalls: groupCalls(
                accept: { _, _ in
                    attempts += 1
                    throw MarmotKitError.GroupInviteNotPending
                },
                refreshed: { terminal },
                snapshotArguments: { snapshotArguments = ($0, $1) }
            )
        )

        let updated = await viewModel.acceptInvite()

        #expect(attempts == 1)
        #expect(updated == terminal)
        #expect(snapshotArguments?.0 == "account-ref")
        #expect(snapshotArguments?.1 == pending.groupIdHex)
        #expect(!viewModel.hasPendingInvite)
        #expect(viewModel.inviteActionInFlight == nil)
    }

    @Test func unrecoverableGroupDisablesComposerBeforeSend() async throws {
        let appState = AppState.test()
        let viewModel = ConversationViewModel(
            appState: appState,
            group: group(name: "damaged", unrecoverable: true)
        )

        #expect(viewModel.isGroupUnrecoverable)
        #expect(!viewModel.canSendMessages)
        #expect(viewModel.inactiveGroupMessage?.contains("rejoined") == true)
    }
}
