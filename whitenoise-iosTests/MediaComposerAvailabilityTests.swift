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
struct MediaComposerAvailabilityTests {

    @Test func v2MediaComponentEnablesAttachments() throws {
        let viewModel = ConversationViewModel(
            appState: AppState.test(),
            group: group(name: "media-ready")
        )

        #expect(viewModel.canSendMediaAttachments)
        #expect(viewModel.canAddMediaAttachments)
    }

    @Test func v1MediaComponentStillEnablesAttachments() throws {
        let viewModel = ConversationViewModel(
            appState: AppState.test(),
            group: group(
                name: "legacy-media-ready",
                encryptedMedia: encryptedMediaComponent(version: .v1)
            )
        )

        #expect(viewModel.canSendMediaAttachments)
    }

    @Test func untypedMediaComponentDoesNotEnableAttachmentsFromLegacyString() throws {
        let component = AppGroupEncryptedMediaComponentFfi(
            componentId: 0x800b,
            component: "marmot.group.encrypted-media.v2",
            required: true,
            version: nil,
            mediaFormat: EncryptedMediaVersionFfi.v2.wireValue,
            allowedLocatorKinds: ["blossom-v1"],
            defaultBlobEndpoints: []
        )
        let viewModel = ConversationViewModel(
            appState: AppState.test(),
            group: group(name: "unknown-media", encryptedMedia: component)
        )

        #expect(!viewModel.canSendMediaAttachments)
    }

    @Test func legacyGroupWithoutMediaComponentDisablesAttachments() throws {
        let viewModel = ConversationViewModel(
            appState: AppState.test(),
            group: group(name: "legacy", encryptedMedia: legacyEncryptedMediaComponent())
        )

        #expect(!viewModel.canSendMediaAttachments)
        #expect(!viewModel.canAddMediaAttachments)
    }

    @Test func pendingInviteDisablesComposerAndAttachments() throws {
        let viewModel = ConversationViewModel(
            appState: AppState.test(),
            group: group(name: "invited", pendingConfirmation: true)
        )

        #expect(viewModel.hasPendingInvite)
        #expect(!viewModel.canSendMessages)
        #expect(!viewModel.canSendMediaAttachments)
        #expect(!viewModel.canAddMediaAttachments)
        #expect(viewModel.sendBlockedMessage == nil)
    }

    @Test func inactiveMembershipDisablesComposerAndAttachments() throws {
        let me = hex("11")
        let other = hex("22")
        let viewModel = ConversationViewModel(
            appState: AppState.test(),
            group: group(name: "removed")
        )
        viewModel.applyGroupMutation(
            GroupMutationResultFfi(
                summary: SendSummaryFfi(published: 0, messageIds: []),
                details: GroupDetailsFfi(
                    group: group(name: "removed", admins: [other]),
                    members: [
                        groupMember(memberIdHex: other, isAdmin: true, isSelf: false)
                    ]
                ),
                managementState: GroupManagementStateFfi(
                    myAccountIdHex: me,
                    isSelfAdmin: false,
                    isLastAdmin: false,
                    canInvite: false,
                    canLeave: false,
                    requiresSelfDemoteBeforeLeave: false,
                    memberActions: [
                        GroupMemberActionStateFfi(
                            memberIdHex: other,
                            isSelf: false,
                            isAdmin: true,
                            canRemove: false,
                            canPromote: false,
                            canDemote: false
                        )
                    ]
                )
            )
        )

        #expect(!viewModel.canSendMessages)
        #expect(viewModel.inactiveGroupMessage == GroupManagementPresentation.inactiveGroupComposerMessage)
        #expect(!viewModel.canSendMediaAttachments)
        #expect(!viewModel.canAddMediaAttachments)
    }

    @Test func durablePendingLeaveFromGroupDetailsDisablesComposer() throws {
        let me = hex("11")
        let other = hex("22")
        let viewModel = ConversationViewModel(
            appState: AppState.test(),
            group: group(name: "leaving"),
            leaveRequestPending: true
        )

        viewModel.applyGroupMutation(
            GroupMutationResultFfi(
                summary: SendSummaryFfi(published: 0, messageIds: []),
                details: GroupDetailsFfi(
                    group: group(name: "leaving", admins: [other], leaveRequestPending: true),
                    members: [
                        groupMember(memberIdHex: me, isAdmin: false, isSelf: true),
                        groupMember(memberIdHex: other, isAdmin: true, isSelf: false),
                    ]
                ),
                managementState: GroupManagementStateFfi(
                    myAccountIdHex: me,
                    isSelfAdmin: false,
                    isLastAdmin: false,
                    canInvite: false,
                    canLeave: false,
                    requiresSelfDemoteBeforeLeave: false,
                    leaveRequestPending: true,
                    leaveRequestedAtMs: 1_000,
                    memberActions: [
                        GroupMemberActionStateFfi(
                            memberIdHex: me,
                            isSelf: true,
                            isAdmin: false,
                            canRemove: false,
                            canPromote: false,
                            canDemote: false
                        )
                    ]
                )
            )
        )

        #expect(viewModel.leaveRequestPending)
        #expect(!viewModel.canSendMessages)
        #expect(viewModel.inactiveGroupMessage == GroupManagementPresentation.leavingGroupComposerMessage)
        #expect(!viewModel.canSendMediaAttachments)
    }

    @Test func resolvedTerminalLeaveClearsPendingProjection() throws {
        let viewModel = ConversationViewModel(
            appState: AppState.test(),
            group: group(name: "leaving"),
            leaveRequestPending: true
        )

        viewModel.applyGroupRecord(group(
            name: "left",
            selfMembership: .left
        ))

        #expect(!viewModel.leaveRequestPending)
        #expect(!viewModel.canSendMessages)
        #expect(viewModel.inactiveGroupMessage == GroupManagementPresentation.leftGroupComposerMessage)
    }

    @Test func publishedTerminalLeaveCanRemainPending() throws {
        let viewModel = ConversationViewModel(
            appState: AppState.test(),
            group: group(name: "leaving")
        )

        viewModel.applyGroupRecord(group(
            name: "leaving",
            selfMembership: .left,
            leaveRequestPending: true
        ))

        #expect(viewModel.leaveRequestPending)
        #expect(!viewModel.canSendMessages)
        // The departure is settled even though the group has not committed the
        // removal, and that commit may never arrive — reporting it as progress
        // is what stranded these chats.
        #expect(viewModel.departureStatus == .membershipEnded(.left))
        #expect(viewModel.inactiveGroupMessage == GroupManagementPresentation.leftGroupComposerMessage)
    }

    @Test func attachmentButtonUsesDisabledAppearanceWhenMediaIsUnavailable() {
        let enabled = ComposerAttachmentButtonAppearance.mediaAvailability(true)
        let disabled = ComposerAttachmentButtonAppearance.mediaAvailability(false)

        #expect(enabled.iconTone == .primary)
        #expect(enabled.chromeInteractive)
        #expect(enabled.controlOpacity == 1)
        #expect(enabled.tapBehavior == .showOptions)
        #expect(disabled.iconTone == .disabled)
        #expect(!disabled.chromeInteractive)
        #expect(disabled.controlOpacity < enabled.controlOpacity)
        #expect(disabled.tapBehavior == .showUnavailableTooltip)
    }

    @Test func inactiveComposerReplacesMessageInput() {
        #expect(ComposerAvailabilityPresentation.showsInput(disabledMessage: nil))
        #expect(!ComposerAvailabilityPresentation.showsInput(
            disabledMessage: GroupManagementPresentation.leftGroupComposerMessage
        ))
    }

    @Test func sendBlockedNoticeWaitsForADraft() {
        let blocked = L10n.string("This chat is still getting ready. Give it a moment.")

        #expect(ComposerAvailabilityPresentation.sendBlockedNotice(
            sendBlockedMessage: blocked, hasSendableContent: false) == nil)
        #expect(ComposerAvailabilityPresentation.sendBlockedNotice(
            sendBlockedMessage: blocked, hasSendableContent: true) == blocked)
        #expect(ComposerAvailabilityPresentation.sendBlockedNotice(
            sendBlockedMessage: nil, hasSendableContent: true) == nil)
    }

    @Test func openingConversationWindowAwaitsLiveState() {
        #expect(ComposerAvailabilityPresentation.awaitsLiveConversationState(
            usesLiveWindow: true,
            hasWindowSnapshot: false,
            hasLiveEpoch: false,
            hasWindowSubscription: false,
            isLocallyReset: false,
            isActiveParticipant: true
        ))
        #expect(ComposerAvailabilityPresentation.awaitsLiveConversationState(
            usesLiveWindow: true,
            hasWindowSnapshot: false,
            hasLiveEpoch: false,
            hasWindowSubscription: true,
            isLocallyReset: false,
            isActiveParticipant: true
        ))
        #expect(ComposerAvailabilityPresentation.awaitsLiveConversationState(
            usesLiveWindow: true,
            hasWindowSnapshot: true,
            hasLiveEpoch: true,
            hasWindowSubscription: false,
            isLocallyReset: false,
            isActiveParticipant: true
        ))
    }

    @Test func attachedConversationWindowReportsLiveState() {
        #expect(!ComposerAvailabilityPresentation.awaitsLiveConversationState(
            usesLiveWindow: true,
            hasWindowSnapshot: true,
            hasLiveEpoch: true,
            hasWindowSubscription: true,
            isLocallyReset: false,
            isActiveParticipant: true
        ))
        #expect(!ComposerAvailabilityPresentation.awaitsLiveConversationState(
            usesLiveWindow: false,
            hasWindowSnapshot: false,
            hasLiveEpoch: false,
            hasWindowSubscription: false,
            isLocallyReset: false,
            isActiveParticipant: true
        ))
    }

    @Test func locallyResetConversationDoesNotAwaitLiveState() {
        #expect(!ComposerAvailabilityPresentation.awaitsLiveConversationState(
            usesLiveWindow: true,
            hasWindowSnapshot: false,
            hasLiveEpoch: false,
            hasWindowSubscription: false,
            isLocallyReset: true,
            isActiveParticipant: true
        ))
    }

    @Test func cachedConversationKeepsTheComposerWhileLiveCapabilitiesLoad() {
        #expect(ComposerAvailabilityPresentation.awaitsLiveConversationState(
            usesLiveWindow: true,
            hasWindowSnapshot: true,
            hasLiveEpoch: false,
            hasWindowSubscription: true,
            isLocallyReset: false,
            isActiveParticipant: true
        ))
    }

    @Test func inactiveMembershipDoesNotWaitForLiveCapabilities() {
        // MDK preserves departed membership in its local-only snapshot even
        // while the epoch and live send permissions are unavailable.
        #expect(!ComposerAvailabilityPresentation.awaitsLiveConversationState(
            usesLiveWindow: true,
            hasWindowSnapshot: true,
            hasLiveEpoch: false,
            hasWindowSubscription: true,
            isLocallyReset: false,
            isActiveParticipant: false
        ))
    }

    @Test func missingLiveStateStopsHidingTheUnavailableNoticeAfterTheGracePeriod() {
        // Neither a stalled open nor repeated local-only snapshots may hide
        // the unavailable notice indefinitely.
        for hasSnapshot in [false, true] {
            for hasSubscription in [false, true] {
                #expect(!ComposerAvailabilityPresentation.awaitsLiveConversationState(
                    usesLiveWindow: true,
                    hasWindowSnapshot: hasSnapshot,
                    hasLiveEpoch: false,
                    hasWindowSubscription: hasSubscription,
                    isLocallyReset: false,
                    isActiveParticipant: true,
                    hasLoadingGraceExpired: true
                ))
            }
        }
    }

    @Test func freshConversationReportsGroupDerivedComposerMessages() throws {
        let appState = AppState.test()
        let disbanded = ConversationViewModel(appState: appState, group: group(name: "ended", disbanded: true))
        let left = ConversationViewModel(appState: appState, group: group(name: "gone", selfMembership: .left))

        #expect(!disbanded.isAwaitingLiveConversationState)
        #expect(disbanded.inactiveGroupMessage == GroupManagementPresentation.disbandedComposerMessage)
        #expect(left.inactiveGroupMessage == GroupManagementPresentation.leftGroupComposerMessage)
    }
}

private func legacyEncryptedMediaComponent() -> AppGroupEncryptedMediaComponentFfi {
    AppGroupEncryptedMediaComponentFfi(
        componentId: 0,
        component: "",
        required: false,
        version: nil,
        mediaFormat: "",
        allowedLocatorKinds: [],
        defaultBlobEndpoints: []
    )
}
