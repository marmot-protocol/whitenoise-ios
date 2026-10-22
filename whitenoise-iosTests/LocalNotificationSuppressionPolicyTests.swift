import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

struct LocalNotificationSuppressionPolicyTests {

    @Test func visibleDestinationChatSuppressesMatchingNotificationOnly() {
        let visibleChat = VisibleChatRoute(accountRef: "account-a", groupIdHex: "group-a")

        #expect(!LocalNotificationSuppressionPolicy.shouldPresent(
            localNotificationsEnabled: true,
            appSceneActive: true,
            updateAccountRef: "account-a",
            updateGroupIdHex: "group-a",
            visibleChat: visibleChat
        ))
        #expect(LocalNotificationSuppressionPolicy.shouldPresent(
            localNotificationsEnabled: true,
            appSceneActive: true,
            updateAccountRef: "account-a",
            updateGroupIdHex: "group-b",
            visibleChat: visibleChat
        ))
        #expect(LocalNotificationSuppressionPolicy.shouldPresent(
            localNotificationsEnabled: true,
            appSceneActive: true,
            updateAccountRef: "account-b",
            updateGroupIdHex: "group-a",
            visibleChat: visibleChat
        ))
        #expect(LocalNotificationSuppressionPolicy.shouldPresent(
            localNotificationsEnabled: true,
            appSceneActive: true,
            updateAccountRef: "account-a",
            updateGroupIdHex: "group-a",
            visibleChat: nil
        ))
    }

    @Test func inactiveAppScenePresentsNotificationsEvenWhenChatRouteMatches() {
        #expect(LocalNotificationSuppressionPolicy.shouldPresent(
            localNotificationsEnabled: true,
            appSceneActive: false,
            updateAccountRef: "account-a",
            updateGroupIdHex: "group-a",
            visibleChat: VisibleChatRoute(accountRef: "account-a", groupIdHex: "group-a")
        ))
    }

    @Test func disabledLocalNotificationsAreNeverPresented() {
        #expect(!LocalNotificationSuppressionPolicy.shouldPresent(
            localNotificationsEnabled: false,
            appSceneActive: false,
            updateAccountRef: "account-a",
            updateGroupIdHex: "group-a",
            visibleChat: nil
        ))
    }

    @Test func archivedNotificationsAreNeverPresented() {
        #expect(!LocalNotificationSuppressionPolicy.shouldPresent(
            localNotificationsEnabled: true,
            isArchived: true,
            appSceneActive: false,
            updateAccountRef: "account-a",
            updateGroupIdHex: "group-a",
            visibleChat: nil
        ))
    }

    @Test func mutedChatMentionFollowsTheBreakThroughPreference() {
        for (isMention, breakThrough, expected) in [
            (true, true, true),
            (true, false, false),
            (false, true, false),
            (false, false, false),
        ] {
            #expect(LocalNotificationSuppressionPolicy.shouldPresent(
                localNotificationsEnabled: true,
                notifyMode: .nothing,
                isMention: isMention,
                mentionsBreakThroughMute: breakThrough,
                appSceneActive: false,
                updateAccountRef: "account-a",
                updateGroupIdHex: "group-a",
                visibleChat: nil
            ) == expected, "mention=\(isMention) breakThrough=\(breakThrough)")
        }
    }

    @Test func breakingThroughMentionStillRespectsTheVisibleChat() {
        // Foreground, another chat visible: the muted chat's mention banners.
        #expect(LocalNotificationSuppressionPolicy.shouldPresent(
            localNotificationsEnabled: true,
            notifyMode: .nothing,
            isMention: true,
            mentionsBreakThroughMute: true,
            appSceneActive: true,
            updateAccountRef: "account-a",
            updateGroupIdHex: "group-a",
            visibleChat: VisibleChatRoute(accountRef: "account-a", groupIdHex: "group-b")
        ))
        // Foreground, the muted chat itself visible: still suppressed.
        #expect(!LocalNotificationSuppressionPolicy.shouldPresent(
            localNotificationsEnabled: true,
            notifyMode: .nothing,
            isMention: true,
            mentionsBreakThroughMute: true,
            appSceneActive: true,
            updateAccountRef: "account-a",
            updateGroupIdHex: "group-a",
            visibleChat: VisibleChatRoute(accountRef: "account-a", groupIdHex: "group-a")
        ))
        // Foreground, nothing visible (e.g. Chats list): presents.
        #expect(LocalNotificationSuppressionPolicy.shouldPresent(
            localNotificationsEnabled: true,
            notifyMode: .nothing,
            isMention: true,
            mentionsBreakThroughMute: true,
            appSceneActive: true,
            updateAccountRef: "account-a",
            updateGroupIdHex: "group-a",
            visibleChat: nil
        ))
    }

    @Test func breakingThroughMentionNeverOverridesDisabledOrArchived() {
        #expect(!LocalNotificationSuppressionPolicy.shouldPresent(
            localNotificationsEnabled: false,
            notifyMode: .nothing,
            isMention: true,
            mentionsBreakThroughMute: true,
            appSceneActive: false,
            updateAccountRef: "account-a",
            updateGroupIdHex: "group-a",
            visibleChat: nil
        ))
        #expect(!LocalNotificationSuppressionPolicy.shouldPresent(
            localNotificationsEnabled: true,
            isArchived: true,
            notifyMode: .nothing,
            isMention: true,
            mentionsBreakThroughMute: true,
            appSceneActive: false,
            updateAccountRef: "account-a",
            updateGroupIdHex: "group-a",
            visibleChat: nil
        ))
    }

    @Test func breakThroughPreferenceLeavesUnmutedAndMentionsOnlyModesUnchanged() {
        for breakThrough in [true, false] {
            for isMention in [true, false] {
                #expect(LocalNotificationSuppressionPolicy.shouldPresent(
                    localNotificationsEnabled: true,
                    notifyMode: .all,
                    isMention: isMention,
                    mentionsBreakThroughMute: breakThrough,
                    appSceneActive: false,
                    updateAccountRef: "account-a",
                    updateGroupIdHex: "group-a",
                    visibleChat: nil
                ))
                #expect(LocalNotificationSuppressionPolicy.shouldPresent(
                    localNotificationsEnabled: true,
                    notifyMode: .mentionsOnly,
                    isMention: isMention,
                    mentionsBreakThroughMute: breakThrough,
                    appSceneActive: false,
                    updateAccountRef: "account-a",
                    updateGroupIdHex: "group-a",
                    visibleChat: nil
                ) == isMention)
            }
        }
    }

    @Test func storedNotificationBreaksThroughOnlyWithExplicitMentionMetadata() {
        let account = [LocalNotificationProjection.accountIdHexKey: hex("11")]
        let mention = account.merging([LocalNotificationProjection.isMentionKey: "1"]) { _, new in new }
        let plain = account.merging([LocalNotificationProjection.isMentionKey: "0"]) { _, new in new }

        #expect(LocalNotificationSuppressionPolicy.storedNotificationBreaksThroughMute(
            userInfo: mention, preference: true
        ))
        #expect(!LocalNotificationSuppressionPolicy.storedNotificationBreaksThroughMute(
            userInfo: mention, preference: false
        ))
        #expect(!LocalNotificationSuppressionPolicy.storedNotificationBreaksThroughMute(
            userInfo: plain, preference: true
        ))
        // A missing mention bit reads as a mention for mentions-only, but it
        // must not un-mute a muted chat.
        #expect(LocalNotificationProjection.isMention(from: account))
        #expect(!LocalNotificationSuppressionPolicy.storedNotificationBreaksThroughMute(
            userInfo: account, preference: true
        ))
        // Without the account id the chat's mute state can't be resolved.
        #expect(!LocalNotificationSuppressionPolicy.storedNotificationBreaksThroughMute(
            userInfo: [LocalNotificationProjection.isMentionKey: "1"], preference: true
        ))
    }
}
