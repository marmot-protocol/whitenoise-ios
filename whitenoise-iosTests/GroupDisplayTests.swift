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
@Suite(.tags(.runtime))
struct GroupDisplayTests {

    @Test func otherMemberUsesMemberIdNotLocalAccountLabel() {
        let me = hex("11")
        let other = hex("22")
        let members = [
            AppGroupMemberRecordFfi(memberIdHex: me, account: "Jeff", local: true),
            AppGroupMemberRecordFfi(memberIdHex: other, account: nil, local: false)
        ]

        #expect(GroupDisplay.otherMemberAccount(in: members, myAccountId: me) == other)
    }

    @Test func resolvedGroupSanitizesNameOnceForTitleAvatarAndSeed() throws {
        let appState = AppState.test(client: try MarmotClient.testClient())
        let other = hex("22")
        var sanitizeCalls = 0
        let display = GroupDisplay.resolve(
            group: group(name: ""),
            otherMember: other,
            memberCount: 2,
            sanitizeGroupName: { raw in
                sanitizeCalls += 1
                return ContentSanitizer.groupName(raw)
            }
        )

        let title = GroupDisplay.title(for: display, appState: appState)
        let avatar = GroupDisplay.avatarURL(for: display, appState: appState)
        let seed = GroupDisplay.avatarSeed(for: display)

        #expect(title == appState.shortNpub(forAccountIdHex: other))
        #expect(avatar == nil)
        #expect(seed == other)
        #expect(sanitizeCalls == 1)
    }

    @Test func namedGroupTitleWinsOverMemberRules() throws {
        let appState = AppState.test(client: try MarmotClient.testClient())
        let display = GroupDisplay.resolve(
            group: group(name: "  Project Room  "),
            otherMember: hex("22"),
            memberCount: 2
        )
        let title = GroupDisplay.title(for: display, appState: appState)

        #expect(title == "Project Room")
    }

    @Test func unnamedMultiPersonGroupShowsCount() throws {
        try withAppLanguage(.english) {
            let appState = AppState.test(client: try MarmotClient.testClient())
            let display = GroupDisplay.resolve(
                group: group(name: ""),
                otherMember: hex("22"),
                memberCount: 3
            )
            let title = GroupDisplay.title(for: display, appState: appState)

            #expect(title == "3 person group")
        }
    }

    @Test func unnamedTwoPersonGroupFallsBackToOtherIdentity() throws {
        let appState = AppState.test(client: try MarmotClient.testClient())
        let other = hex("22")
        let display = GroupDisplay.resolve(
            group: group(name: ""),
            otherMember: other,
            memberCount: 2
        )

        let title = GroupDisplay.title(for: display, appState: appState)

        // With no known profile for the peer, a 2-person group resolves to the
        // other member's npub. Name resolution is covered by
        // ResolvedDisplayNameTests now that iOS reads profiles from the binding.
        #expect(title == appState.shortNpub(forAccountIdHex: other))
    }

    @Test func unnamedTwoPersonGroupFallsBackToNpub() throws {
        let appState = AppState.test(client: try MarmotClient.testClient())
        let display = GroupDisplay.resolve(
            group: group(name: ""),
            otherMember: hex("22"),
            memberCount: 2
        )
        let title = GroupDisplay.title(for: display, appState: appState)

        #expect(title.hasPrefix("npub1"))
    }

    @Test func groupAvatarURLWinsOverDirectMessageFallback() throws {
        let appState = AppState.test(client: try MarmotClient.testClient())
        let display = GroupDisplay.resolve(
            group: group(name: "", avatarUrl: "https://cdn.example.com/group.png"),
            otherMember: hex("22"),
            memberCount: 2
        )
        let avatar = GroupDisplay.avatarURL(for: display, appState: appState)

        #expect(avatar?.absoluteString == "https://cdn.example.com/group.png")
    }

    @Test func groupAvatarURLRejectsUnsafeGroupURL() throws {
        let appState = AppState.test(client: try MarmotClient.testClient())
        let display = GroupDisplay.resolve(
            group: group(name: "Unsafe", avatarUrl: "http://127.0.0.1/group.png"),
            otherMember: hex("22"),
            memberCount: 3
        )
        let avatar = GroupDisplay.avatarURL(for: display, appState: appState)

        #expect(avatar == nil)
    }
}
