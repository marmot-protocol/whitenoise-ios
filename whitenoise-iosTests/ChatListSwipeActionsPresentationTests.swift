import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

struct ChatListSwipeActionsPresentationTests {
    @Test func activeMemberShowsLeaveAndArchive() {
        let actions = ChatListSwipeActionsPresentation.trailingActions(
            isArchived: false,
            selfMembership: .member,
            leaveRequestPending: false,
            isMuted: false
        )
        #expect(actions.contains(.leave))
        #expect(actions.contains(.archive))
        #expect(!actions.contains(.delete))
        #expect(!actions.contains(.unarchive))
    }

    @Test func inactiveMemberShowsDeleteAndArchive() {
        let actions = ChatListSwipeActionsPresentation.trailingActions(
            isArchived: false,
            selfMembership: .removed,
            leaveRequestPending: false,
            isMuted: false
        )
        #expect(actions.contains(.delete))
        #expect(actions.contains(.archive))
        #expect(!actions.contains(.leave))
        #expect(!actions.contains(.unarchive))
    }

    @Test func archivedActiveMemberShowsUnarchiveAndLeave() {
        let actions = ChatListSwipeActionsPresentation.trailingActions(
            isArchived: true,
            selfMembership: .member,
            leaveRequestPending: false,
            isMuted: false
        )
        #expect(actions.contains(.unarchive))
        #expect(actions.contains(.leave))
        #expect(!actions.contains(.delete))
        #expect(!actions.contains(.archive))
    }

    @Test func archivedInactiveMemberShowsUnarchiveAndDelete() {
        let actions = ChatListSwipeActionsPresentation.trailingActions(
            isArchived: true,
            selfMembership: .left,
            leaveRequestPending: false,
            isMuted: false
        )
        #expect(actions.contains(.unarchive))
        #expect(actions.contains(.delete))
        #expect(!actions.contains(.leave))
        #expect(!actions.contains(.archive))
    }

    @Test func bulkLocalDeleteRequiresEverySelectedMembershipToBeInactive() {
        #expect(!ChatListSelection.canDeleteLocally([]))
        #expect(ChatListSelection.canDeleteLocally([.deleteLocally]))
        #expect(ChatListSelection.canDeleteLocally([.deleteLocally, .deleteLocally]))
        #expect(!ChatListSelection.canDeleteLocally([.leave]))
        #expect(!ChatListSelection.canDeleteLocally([.deleteLocally, .leave]))
        #expect(!ChatListSelection.canDeleteLocally([nil]))
        #expect(!ChatListSelection.canDeleteLocally([.deleteLocally, nil]))
    }
}
