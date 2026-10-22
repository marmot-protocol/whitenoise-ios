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
        let appState = AppState.test(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account-ref"
        let pending = group(
            name: "invited",
            pendingConfirmation: true,
            welcomerAccountIdHex: hex("44")
        )
        let viewModel = ConversationViewModel(appState: appState, group: pending)
        var receivedArguments: (String, String)?
        viewModel.acceptGroupInviteForTesting = { accountRef, groupIdHex in
            receivedArguments = (accountRef, groupIdHex)
            return group(name: "invited", id: groupIdHex)
        }

        let updated = await viewModel.acceptInvite()

        #expect(receivedArguments?.0 == "account-ref")
        #expect(receivedArguments?.1 == pending.groupIdHex)
        #expect(updated?.pendingConfirmation == false)
        #expect(!viewModel.hasPendingInvite)
        #expect(viewModel.inviteActionInFlight == nil)
    }

    @Test func declineAppliesArchivedInactiveGroup() async throws {
        let appState = AppState.test(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account-ref"
        let pending = group(name: "invited", pendingConfirmation: true)
        let viewModel = ConversationViewModel(appState: appState, group: pending)
        let declined = group(
            name: "invited",
            id: pending.groupIdHex,
            archived: true,
            selfMembership: .left
        )
        viewModel.declineGroupInviteForTesting = { _, _ in
            GroupInviteDeclineResultFfi(
                group: declined,
                summary: SendSummaryFfi(published: 1, messageIds: [])
            )
        }

        let updated = await viewModel.declineInvite()

        #expect(updated == declined)
        #expect(viewModel.group == declined)
        #expect(!viewModel.hasPendingInvite)
        #expect(!viewModel.canSendMessages)
        #expect(viewModel.inviteActionInFlight == nil)
    }

    @Test func acceptRetriesOnceWhenWorkerIsDefinitelyBusy() async throws {
        let appState = AppState.test(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account-ref"
        let pending = group(name: "invited", pendingConfirmation: true)
        let viewModel = ConversationViewModel(appState: appState, group: pending)
        var attempts = 0
        var refreshes = 0
        viewModel.acceptGroupInviteForTesting = { _, groupIdHex in
            attempts += 1
            if attempts == 1 {
                throw MarmotKitError.AccountWorkerBusy
            }
            return group(name: "invited", id: groupIdHex)
        }
        viewModel.refreshInviteStateForTesting = {
            refreshes += 1
            return true
        }

        let updated = await viewModel.acceptInvite()

        #expect(attempts == 2)
        #expect(refreshes == 1)
        #expect(updated?.pendingConfirmation == false)
        #expect(!viewModel.hasPendingInvite)
    }

    @Test func acceptTimeoutRefreshesStateWithoutRetryingAmbiguousOperation() async throws {
        let appState = AppState.test(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account-ref"
        let pending = group(name: "invited", pendingConfirmation: true)
        let viewModel = ConversationViewModel(appState: appState, group: pending)
        var attempts = 0
        viewModel.acceptGroupInviteForTesting = { _, _ in
            attempts += 1
            throw MarmotKitError.AccountWorkerResponseTimedOut
        }
        viewModel.refreshInviteStateForTesting = {
            viewModel.applyGroupRecord(group(name: "invited", id: pending.groupIdHex))
            return true
        }

        let updated = await viewModel.acceptInvite()

        #expect(attempts == 1)
        #expect(updated?.pendingConfirmation == false)
        #expect(!viewModel.hasPendingInvite)
    }

    @Test func staleAcceptRefreshesTheTerminalGroupWithoutRetrying() async throws {
        let appState = AppState.test(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account-ref"
        let pending = group(name: "invited", pendingConfirmation: true)
        let viewModel = ConversationViewModel(appState: appState, group: pending)
        let terminal = group(
            name: "invited",
            id: pending.groupIdHex,
            archived: true,
            selfMembership: .left
        )
        var attempts = 0
        viewModel.acceptGroupInviteForTesting = { _, _ in
            attempts += 1
            throw MarmotKitError.GroupInviteNotPending
        }
        viewModel.refreshInviteStateForTesting = {
            viewModel.applyGroupRecord(terminal)
            return true
        }

        let updated = await viewModel.acceptInvite()

        #expect(attempts == 1)
        #expect(updated == terminal)
        #expect(!viewModel.hasPendingInvite)
        #expect(viewModel.inviteActionInFlight == nil)
    }

    @Test func unrecoverableGroupDisablesComposerBeforeSend() async throws {
        let appState = AppState.test(client: try MarmotClient.testClient())
        let viewModel = ConversationViewModel(
            appState: appState,
            group: group(name: "damaged", unrecoverable: true)
        )

        #expect(viewModel.isGroupUnrecoverable)
        #expect(!viewModel.canSendMessages)
        #expect(viewModel.inactiveGroupMessage?.contains("rejoined") == true)
    }
}
