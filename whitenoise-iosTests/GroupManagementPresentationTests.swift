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
struct GroupManagementPresentationTests {

    @Test func adminCanPromoteAndRemoveNonAdminMember() {
        let actions = GroupManagementPresentation.memberActions(
            for: GroupMemberActionStateFfi(
                memberIdHex: hex("22"),
                isSelf: false,
                isAdmin: false,
                canRemove: true,
                canPromote: true,
                canDemote: false
            ),
            state: managementState(isSelfAdmin: true, isLastAdmin: false)
        )

        #expect(actions == [.promote, .remove])
    }

    @Test func adminCanDemoteAndRemoveAnotherAdminWhenNotLastAdmin() {
        let actions = GroupManagementPresentation.memberActions(
            for: GroupMemberActionStateFfi(
                memberIdHex: hex("22"),
                isSelf: false,
                isAdmin: true,
                canRemove: true,
                canPromote: false,
                canDemote: true
            ),
            state: managementState(isSelfAdmin: true, isLastAdmin: false)
        )

        #expect(actions == [.demote, .remove])
    }

    @Test func selfAdminCanStepDownOnlyWhenAnotherAdminExists() {
        let selfAction = GroupMemberActionStateFfi(
            memberIdHex: hex("11"),
            isSelf: true,
            isAdmin: true,
            canRemove: false,
            canPromote: false,
            canDemote: false
        )

        #expect(
            GroupManagementPresentation.memberActions(
                for: selfAction,
                state: managementState(isSelfAdmin: true, isLastAdmin: false)
            ) == [.selfDemote]
        )
        #expect(
            GroupManagementPresentation.memberActions(
                for: selfAction,
                state: managementState(isSelfAdmin: true, isLastAdmin: true)
            ).isEmpty
        )
    }

    @Test func nonLastAdminsCanLeaveWithAutomaticDemotion() {
        let state = managementState(
            isSelfAdmin: true,
            isLastAdmin: false,
            canLeave: false,
            requiresSelfDemoteBeforeLeave: true
        )

        #expect(GroupManagementPresentation.canLeave(state: state, fallbackIsLastAdmin: false))
        #expect(GroupManagementPresentation.shouldSelfDemoteBeforeLeave(state: state))
        #expect(GroupManagementPresentation.leaveFooter(state: state, fallbackIsLastAdmin: false) == "Leaving will step you down as admin first.")
        #expect(GroupManagementPresentation.leaveConfirmationMessage(state: state) == "You'll step down as admin first, then stop receiving messages from this group.")
    }

    @Test func lastAdminStillCannotLeave() {
        let state = managementState(
            isSelfAdmin: true,
            isLastAdmin: true,
            canLeave: false,
            requiresSelfDemoteBeforeLeave: true
        )

        #expect(!GroupManagementPresentation.canLeave(state: state, fallbackIsLastAdmin: false))
        #expect(!GroupManagementPresentation.shouldSelfDemoteBeforeLeave(state: state))
        #expect(GroupManagementPresentation.leaveFooter(state: state, fallbackIsLastAdmin: false) == "You're the only admin. Make another member an admin before you leave.")
    }

    @Test func terminalMembershipOverridesStaleActiveManagementState() {
        let state = managementState(
            isSelfAdmin: false,
            isLastAdmin: false,
            canLeave: true
        )

        #expect(!GroupManagementPresentation.isActiveMember(
            state: state,
            members: [],
            groupMemberDetails: [],
            myAccountId: state.myAccountIdHex,
            fallbackSelfMembership: .left
        ))
        #expect(!GroupManagementPresentation.isActiveMember(
            state: state,
            members: [],
            groupMemberDetails: [],
            myAccountId: state.myAccountIdHex,
            fallbackSelfMembership: .removed
        ))
    }

    @Test func pendingLeaveDisablesMembershipAndLeaveAffordances() {
        let state = managementState(
            isSelfAdmin: false,
            isLastAdmin: false,
            canLeave: false,
            leaveRequestPending: true
        )

        #expect(!GroupManagementPresentation.canLeave(state: state, fallbackIsLastAdmin: false))
        #expect(!GroupManagementPresentation.isActiveMember(
            state: state,
            members: [],
            groupMemberDetails: [],
            myAccountId: state.myAccountIdHex
        ))
        #expect(GroupManagementPresentation.leaveFooter(
            state: state,
            fallbackIsLastAdmin: false
        ) == GroupManagementPresentation.leavingGroupComposerMessage)
    }

    @Test func adminCanEndGroupWhenLifecycleCanBeEnabledOrIsAlreadyEnabled() {
        let canEnable = managementState(
            isSelfAdmin: true,
            isLastAdmin: true,
            canEnableDisbanding: true
        )
        let enabled = managementState(
            isSelfAdmin: true,
            isLastAdmin: true,
            disbandingEnabled: true,
            canDisband: true
        )

        #expect(GroupManagementPresentation.shouldShowEndGroup(state: canEnable))
        #expect(GroupManagementPresentation.canEndGroup(state: canEnable))
        #expect(GroupManagementPresentation.shouldShowEndGroup(state: enabled))
        #expect(GroupManagementPresentation.canEndGroup(state: enabled))
    }

    @Test func incompatibleMembersDisableEndGroupWithUpdateGuidance() {
        let state = managementState(
            isSelfAdmin: true,
            isLastAdmin: true,
            disbandingBlockers: [hex("22"), hex("33")]
        )

        #expect(GroupManagementPresentation.shouldShowEndGroup(state: state))
        #expect(!GroupManagementPresentation.canEndGroup(state: state))
        #expect(
            GroupManagementPresentation.disbandBlockerMessage(state: state)
                == "2 members must update White Noise before you can end this group."
        )
    }

    @Test func pendingAndTerminalDisbandStatesDisableTheComposer() throws {
        let appState = AppState.test(client: try MarmotClient.testClient())
        let pending = group(
            name: "Ending",
            disbanding: true,
            disbandRequest: .pending(requestedAtMs: 1_000)
        )
        let pendingConversation = ConversationViewModel(appState: appState, group: pending)
        let terminal = group(name: "Ended", disbanded: true)
        let terminalConversation = ConversationViewModel(appState: appState, group: terminal)

        #expect(!pendingConversation.canSendMessages)
        #expect(
            pendingConversation.inactiveGroupMessage
                == GroupManagementPresentation.disbandingComposerMessage
        )
        #expect(
            GroupManagementPresentation.disbandStatus(group: pending, state: nil)
                == .pending
        )
        #expect(!terminalConversation.canSendMessages)
        #expect(
            terminalConversation.inactiveGroupMessage
                == GroupManagementPresentation.disbandedComposerMessage
        )
        #expect(
            GroupManagementPresentation.disbandStatus(group: terminal, state: nil)
                == .disbanded
        )
    }

    @Test func failedDisbandRequestExplainsWhyItStopped() {
        let failed = group(
            name: "Not Ended",
            disbandRequest: .failed(requestedAtMs: 1_000, reason: .noLongerAdmin)
        )

        #expect(
            GroupManagementPresentation.disbandStatus(group: failed, state: nil)
                == .failed(.noLongerAdmin)
        )
        #expect(
            GroupManagementPresentation.disbandFailureMessage(.noLongerAdmin)
                == "The group wasn't ended because you're no longer an admin."
        )
    }

    @Test func relaySectionShowsUrls() {
        let relays = ["wss://relay.example", "wss://relay.two"]

        #expect(GroupRelaysPresentation.rows(for: relays) == relays)
    }

    @Test func relaySectionShowsEmptyState() {
        #expect(GroupRelaysPresentation.rows(for: []) == [GroupRelaysPresentation.emptyMessage])
    }

    @Test func addMembersScannerAcceptsProfileDeepLinks() {
        let npub = "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"
        let nprofile = "nprofile1qqsrhuxx8l9ex335q7he0f09aej04zpazpl0ne2cgukyawd24mayt8gpp4mhxue69uhhytnc9e3k7mgpz4mhxue69uhkg6nzv9ejuumpv34kytnrdaksjlyr9p"
        let nprofileHex = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"

        #expect(
            AddMembersPresentation.memberRef(fromScannedPayload: "\(DeepLink.scheme)://profile/\(npub)") == npub
        )
        #expect(
            AddMembersPresentation.memberRef(fromScannedPayload: "marmot-staging://profile/\(npub)") == npub
        )
        #expect(
            AddMembersPresentation.memberRef(fromScannedPayload: "whitenoise://profile/\(npub)") == npub
        )
        #expect(
            AddMembersPresentation.memberRef(fromScannedPayload: "whitenoise-staging://profile/\(npub)") == npub
        )
        #expect(
            AddMembersPresentation.memberRef(fromScannedPayload: "nostr:\(npub)") == npub
        )
        #expect(
            AddMembersPresentation.memberRef(fromScannedPayload: nprofile) == nprofileHex
        )
        #expect(
            AddMembersPresentation.memberRef(fromScannedPayload: "nostr:\(nprofile)") == nprofileHex
        )
        #expect(
            AddMembersPresentation.memberRef(fromScannedPayload: "\(DeepLink.scheme)://profile/\(nprofile)") == nprofileHex
        )
        #expect(
            DeepLink.parse(string: "nostr:\(nprofile)") == .profile(npub: nprofile)
        )
        #expect(NostrProfileReference.memberRef(from: nprofile) == nprofileHex)
        #expect(ProfileReferenceResolution.referenceForResolution(nprofile) == nprofileHex)
        #expect(
            NostrProfileReference.memberRef(from: "3BF0C63FCB93463407AF97A5E5EE64FA883D107EF9E558472C4EB9AAAEFA459D") == "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"
        )
    }

    @Test func encodesNpubFromHexWithoutMarmotFfi() throws {
        let npub = "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"
        let hex = try #require(NostrProfileReference.pubkeyHex(fromBech32: npub))

        #expect(NostrProfileReference.npub(fromAccountIdHex: hex) == npub)
        #expect(NostrProfileReference.npub(fromAccountIdHex: hex.uppercased()) == npub)
        #expect(NostrProfileReference.npub(fromAccountIdHex: "not hex") == nil)
    }

    @Test func addMembersScannerRejectsCorruptNpubReferences() {
        let invalidNpub = "npub1abcdefghijklmnopqrstuvwxyz"

        #expect(NostrProfileReference.memberRef(fromReference: invalidNpub) == nil)
        #expect(AddMembersPresentation.memberRef(fromScannedPayload: invalidNpub) == nil)
        #expect(AddMembersPresentation.memberRef(fromScannedPayload: "nostr:\(invalidNpub)") == nil)
        #expect(
            AddMembersPresentation.memberRef(fromScannedPayload: "whitenoise://profile/\(invalidNpub)") == nil
        )
        #expect(DeepLink.parse(string: "nostr:\(invalidNpub)") == nil)
    }

    @Test func memberRefRejectsNonASCIIHRPWithoutCrashing() {
        // Regression test for issue #35: a bech32 string whose HRP contains a
        // Unicode scalar > 0x1FFF used to trap in bech32VerifyChecksum via
        // UInt8($0.value >> 5). The decoder must reject it and return nil.
        let crafted = "nprofile🎉1qpzry9x8gf2tvdw0s3jn54khce6mua7l"

        #expect(NostrProfileReference.memberRef(from: crafted) == nil)
        #expect(NostrProfileReference.memberRef(fromReference: crafted) == nil)
        #expect(DeepLink.parse(string: "nostr:\(crafted)") == nil)
        #expect(AddMembersPresentation.memberRef(fromScannedPayload: crafted) == nil)
        #expect(
            AddMembersPresentation.memberRef(fromScannedPayload: "whitenoise://profile/\(crafted)") == nil
        )
    }

    @Test func stagedMembersFallBackToNpubWithNpubSubtitle() throws {
        let appState = AppState.test(client: try MarmotClient.testClient())
        let account = hex("33")
        let member = stagedMember(accountIdHex: account)

        // With no known profile, both identity surfaces stay in canonical npub
        // form. (Name resolution from a profile is covered separately.)
        #expect(AddMembersPresentation.displayName(for: member, appState: appState) == appState.shortNpub(forAccountIdHex: account))
        #expect(AddMembersPresentation.secondaryIdentity(for: member).hasPrefix("npub1"))
    }

    private func stagedMember(accountIdHex: String) -> MemberRefFfi {
        MemberRefFfi(
            memberRef: accountIdHex,
            accountIdHex: accountIdHex,
            npub: "npub1abcdefghijklmnopqrstuvwxyz0123456789"
        )
    }

    @Test func adminStatusIgnoresLocalAccountLabelFallback() throws {
        let admin = hex("11")
        let nonAdminMember = AppGroupMemberRecordFfi(
            memberIdHex: hex("22"),
            account: admin,
            local: false
        )
        let viewModel = ConversationViewModel(
            appState: AppState.test(client: try MarmotClient.testClient()),
            group: group(name: "", admins: [admin])
        )

        #expect(!viewModel.isAdmin(nonAdminMember))
    }

    @Test func adminStatusCanUpdateOptimisticallyBeforePublishReturns() throws {
        let me = hex("11")
        let other = hex("22")
        let viewModel = ConversationViewModel(
            appState: AppState.test(client: try MarmotClient.testClient()),
            group: group(name: "")
        )
        viewModel.applyGroupMutation(
            GroupMutationResultFfi(
                summary: SendSummaryFfi(published: 0, messageIds: []),
                details: GroupDetailsFfi(
                    group: group(name: "", admins: [me]),
                    members: [
                        groupMember(memberIdHex: me, isAdmin: true, isSelf: true),
                        groupMember(memberIdHex: other, isAdmin: false, isSelf: false)
                    ]
                ),
                managementState: GroupManagementStateFfi(
                    myAccountIdHex: me,
                    isSelfAdmin: true,
                    isLastAdmin: true,
                    canInvite: true,
                    canLeave: false,
                    requiresSelfDemoteBeforeLeave: true,
                    memberActions: [
                        GroupMemberActionStateFfi(
                            memberIdHex: other,
                            isSelf: false,
                            isAdmin: false,
                            canRemove: true,
                            canPromote: true,
                            canDemote: false
                        )
                    ]
                )
            )
        )

        viewModel.applyOptimisticAdminStatus(memberIdHex: other, isAdmin: true)

        #expect(viewModel.group.admins.contains(other))
        #expect(viewModel.groupMemberDetails.first { $0.memberIdHex == other }?.isAdmin == true)
        #expect(viewModel.managementAction(for: other)?.canPromote == false)
        #expect(viewModel.managementAction(for: other)?.canDemote == true)
        #expect(viewModel.managementState?.isLastAdmin == false)
    }

    @Test func selfDemoteUpdatesOwnManagementStateOptimistically() throws {
        let me = hex("11")
        let other = hex("22")
        let viewModel = ConversationViewModel(
            appState: AppState.test(client: try MarmotClient.testClient()),
            group: group(name: "")
        )
        viewModel.applyGroupMutation(
            GroupMutationResultFfi(
                summary: SendSummaryFfi(published: 0, messageIds: []),
                details: GroupDetailsFfi(
                    group: group(name: "", admins: [me, other]),
                    members: [
                        groupMember(memberIdHex: me, isAdmin: true, isSelf: true),
                        groupMember(memberIdHex: other, isAdmin: true, isSelf: false)
                    ]
                ),
                managementState: GroupManagementStateFfi(
                    myAccountIdHex: me,
                    isSelfAdmin: true,
                    isLastAdmin: false,
                    canInvite: true,
                    canLeave: false,
                    requiresSelfDemoteBeforeLeave: true,
                    memberActions: []
                )
            )
        )

        viewModel.applyOptimisticAdminStatus(memberIdHex: me, isAdmin: false)

        #expect(!viewModel.group.admins.contains(me))
        #expect(viewModel.groupMemberDetails.first { $0.memberIdHex == me }?.isAdmin == false)
        #expect(viewModel.managementState?.isSelfAdmin == false)
        #expect(viewModel.managementState?.requiresSelfDemoteBeforeLeave == false)
        #expect(viewModel.managementState?.canLeave == true)
    }

    @Test func groupMlsRefreshGenerationTracksMembershipInputsOnly() throws {
        let me = hex("11")
        let other = hex("22")
        let viewModel = ConversationViewModel(
            appState: AppState.test(client: try MarmotClient.testClient()),
            group: group(name: "", admins: [me])
        )
        let initialGeneration = viewModel.groupMlsRefreshGeneration

        viewModel.applyGroupRecord(group(name: "Renamed", admins: [me]))

        #expect(viewModel.groupMlsRefreshGeneration == initialGeneration)

        viewModel.applyGroupRecord(group(name: "Renamed", admins: [me, other]))

        #expect(viewModel.groupMlsRefreshGeneration == initialGeneration + 1)

        viewModel.applyGroupMutation(
            GroupMutationResultFfi(
                summary: SendSummaryFfi(published: 0, messageIds: []),
                details: GroupDetailsFfi(
                    group: group(name: "Renamed", admins: [me, other]),
                    members: [
                        groupMember(memberIdHex: me, isAdmin: true, isSelf: true),
                        groupMember(memberIdHex: other, isAdmin: false, isSelf: false)
                    ]
                ),
                managementState: GroupManagementStateFfi(
                    myAccountIdHex: me,
                    isSelfAdmin: true,
                    isLastAdmin: false,
                    canInvite: true,
                    canLeave: true,
                    requiresSelfDemoteBeforeLeave: false,
                    memberActions: []
                )
            )
        )

        #expect(viewModel.groupMlsRefreshGeneration == initialGeneration + 2)
    }
}
