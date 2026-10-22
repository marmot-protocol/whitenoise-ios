import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

struct ConversationInvitePresentationTests {
    @Test func centeredPromptRequiresPendingInviteWithoutMessages() {
        let systemOnly = [
            TimelineItem.systemEvent(id: "created", event: .groupCreated, timestamp: 1)
        ]
        let withMessage = systemOnly + [TimelineItem.message(message(id: hex("91")))]

        #expect(ConversationInvitePresentation.shouldShowCenteredPrompt(
            isPending: true,
            hasError: false,
            isLoading: false,
            timeline: []
        ))
        #expect(ConversationInvitePresentation.shouldShowCenteredPrompt(
            isPending: true,
            hasError: false,
            isLoading: false,
            timeline: systemOnly
        ))
        #expect(!ConversationInvitePresentation.shouldShowCenteredPrompt(
            isPending: true,
            hasError: false,
            isLoading: false,
            timeline: withMessage
        ))
    }

    @Test func invitationTextNamesTheInviterAndFallsBackWhenUnknown() {
        #expect(ConversationInvitePresentation.invitationText(inviterName: "Alice")
            == L10n.formatted("%@ has invited you to a secure chat", "Alice"))
        #expect(ConversationInvitePresentation.invitationText(inviterName: " Alice\n")
            == L10n.formatted("%@ has invited you to a secure chat", "Alice"))
        #expect(ConversationInvitePresentation.invitationText(inviterName: nil)
            == L10n.formatted("%@ has invited you to a secure chat", L10n.string("Someone")))
        #expect(ConversationInvitePresentation.invitationText(inviterName: "   ")
            == L10n.formatted("%@ has invited you to a secure chat", L10n.string("Someone")))
    }

    @Test func inviterAccountIdNormalizationTrimsAndLowercasesForBothSurfaces() {
        let mixedCase = String(repeating: "AB", count: 32)
        let lowercased = String(repeating: "ab", count: 32)

        #expect(ConversationInvitePresentation
            .normalizedInviterAccountId("  \(mixedCase)\n") == lowercased)
        #expect(ConversationInvitePresentation.normalizedInviterAccountId(nil) == nil)
        #expect(ConversationInvitePresentation.normalizedInviterAccountId("   ") == nil)
        #expect(ChatsListViewModel.inviterAccountIdHex(
            pendingConfirmation: true,
            welcomerAccountIdHex: mixedCase,
            directPeerAccountIdHex: nil
        ) == lowercased)
    }

    @Test func centeredPromptDoesNotHideLoadingErrorsOrAcceptedChats() {
        #expect(!ConversationInvitePresentation.shouldShowCenteredPrompt(
            isPending: true,
            hasError: true,
            isLoading: false,
            timeline: []
        ))
        #expect(!ConversationInvitePresentation.shouldShowCenteredPrompt(
            isPending: true,
            hasError: false,
            isLoading: true,
            timeline: []
        ))
        #expect(!ConversationInvitePresentation.shouldShowCenteredPrompt(
            isPending: false,
            hasError: false,
            isLoading: false,
            timeline: []
        ))
    }
}
