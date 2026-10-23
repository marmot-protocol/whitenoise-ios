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
@Suite(.tags(.runtime), .marmotRuntimeConcurrencyLimit)
struct ConversationChromeTests {

    @Test func initialChromeUsesChatListTitleBeforeViewModelLoads() {
        let chrome = ConversationChromePresentation.initial(
            chat: group(name: "", id: hex("aa")),
            initialTitle: "Alice",
            initialMemberCount: nil
        )

        #expect(chrome.title == "Alice")
        #expect(chrome.subtitle == nil)
    }

    @Test func initialChromeReservesKnownMemberSubtitle() {
        // A named group (not a DM) keeps its member-count subtitle.
        let chrome = ConversationChromePresentation.initial(
            chat: group(name: "Project Room", id: hex("aa")),
            initialTitle: nil,
            initialMemberCount: 2
        )

        #expect(chrome.title == "Project Room")
        #expect(chrome.subtitle == "2 members")
    }

    @Test func initialChromeHidesMemberSubtitleForDirectMessageTitledByContactName() {
        // A DM's title hint is the contact's name; it must still be detected as
        // a DM (no member count) from the empty group name.
        let chrome = ConversationChromePresentation.initial(
            chat: group(name: "", id: hex("aa")),
            initialTitle: "Alice",
            initialMemberCount: 2
        )

        #expect(chrome.title == "Alice")
        #expect(chrome.subtitle == nil)
    }

    @Test func initialChromeHidesMemberSubtitleForDirectMessage() {
        let chrome = ConversationChromePresentation.initial(
            chat: group(name: "", id: hex("aa")),
            initialTitle: nil,
            initialMemberCount: 2
        )

        // An unnamed 2-person chat is a DM: no member-count subtitle.
        #expect(chrome.subtitle == nil)
    }

    @Test func directMessageTitleUsesInitialChatListHintsBeforeRosterLoads() throws {
        let appState = AppState.test(client: try MarmotClient.testClient())
        let other = hex("22")

        let viewModel = ConversationViewModel(
            appState: appState,
            group: group(name: ""),
            initialOtherMember: other,
            initialMemberCount: 2
        )

        // The initial-member-count hint drives the 2-person title before the
        // roster loads; with no known profile the title is the peer's npub. A DM
        // shows just the contact's name — no member-count subtitle.
        #expect(viewModel.displayTitle == appState.shortNpub(forAccountIdHex: other))
        #expect(viewModel.displaySubtitle == nil)
    }

    @Test func headerSecondaryShowsConnectingWhileRuntimeWarmsUp() {
        #expect(
            ConversationHeaderSecondary.resolve(isRuntimeWarmingUp: true, subtitle: "2 members")
                == .connecting
        )
    }

    @Test func headerSecondaryShowsSubtitleOnceWarmedUp() {
        #expect(
            ConversationHeaderSecondary.resolve(isRuntimeWarmingUp: false, subtitle: "2 members")
                == .subtitle("2 members")
        )
        #expect(
            ConversationHeaderSecondary.resolve(isRuntimeWarmingUp: false, subtitle: nil)
                == .subtitle(nil)
        )
    }

    @Test func emptyStateLabelsConnectingWhileWarmingUpInsteadOfBareSpinner() {
        #expect(
            ConversationEmptyState.resolve(hasError: false, isLoading: true, isRuntimeWarmingUp: true)
                == .connecting
        )
        #expect(
            ConversationEmptyState.resolve(hasError: false, isLoading: true, isRuntimeWarmingUp: false)
                == .loading
        )
    }

    @Test func emptyStatePrefersErrorThenFallsBackToEmpty() {
        // Error wins even mid-warm-up so a failed load still surfaces Retry.
        #expect(
            ConversationEmptyState.resolve(hasError: true, isLoading: true, isRuntimeWarmingUp: true)
                == .error
        )
        #expect(
            ConversationEmptyState.resolve(hasError: false, isLoading: false, isRuntimeWarmingUp: false)
                == .empty
        )
    }

    @Test func emptyGroupInviteRequiresConfirmedSoleMemberAdmin() {
        #expect(EmptyGroupConversationPresentation.canInvite(
            isSelfMember: true,
            isSelfAdmin: true,
            membersLoaded: true,
            memberCount: 1,
            onlyMemberIsSelf: true
        ))
        #expect(!EmptyGroupConversationPresentation.canInvite(
            isSelfMember: true,
            isSelfAdmin: true,
            membersLoaded: false,
            memberCount: 0,
            onlyMemberIsSelf: false
        ))
        #expect(!EmptyGroupConversationPresentation.canInvite(
            isSelfMember: true,
            isSelfAdmin: false,
            membersLoaded: true,
            memberCount: 1,
            onlyMemberIsSelf: true
        ))
    }

    @Test func activeRetentionReplacesMemberSubtitleButConnectingWins() {
        #expect(ConversationHeaderSecondary.resolve(
            isRuntimeWarmingUp: false,
            subtitle: "4 members",
            retentionSeconds: 300
        ) == .retention(300))
        #expect(ConversationHeaderSecondary.resolve(
            isRuntimeWarmingUp: true,
            subtitle: "4 members",
            retentionSeconds: 300
        ) == .connecting)
    }
}
