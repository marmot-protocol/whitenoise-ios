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
struct NotificationPresentationTests {

    @Test func directMessageUsesSenderPreviewAndRouteMetadata() {
        let update = notificationUpdate(
            notificationKey: "notif-1",
            conversationKey: "conv-1",
            isDm: true,
            groupName: nil,
            senderName: " Alice\nExample ",
            previewText: " hello\u{202E}\nthere ",
            messageIdHex: "message-1"
        )

        let presentation = LocalNotificationProjection.makePresentation(for: update)

        #expect(presentation?.identifier == "notif-1")
        #expect(presentation?.threadIdentifier == "conv-1")
        #expect(presentation?.title == "Alice Example")
        #expect(presentation?.body == "hello there")
        #expect(presentation?.route.accountRef == "account-a")
        #expect(presentation?.route.groupIdHex == "group-a")
        #expect(presentation?.route.messageIdHex == "message-1")
        #expect(presentation?.userInfo[LocalNotificationProjection.accountRefKey] == "account-a")
        #expect(presentation?.userInfo[LocalNotificationProjection.accountIdHexKey] == hex("11"))
    }

    @Test func notificationDeliveryDispositionMarkersAreExplicit() {
        #expect(LocalNotificationProjection.isQuietOrFallback(from: [
            LocalNotificationProjection.deliveryDispositionKey:
                LocalNotificationProjection.quietDisposition,
        ]))
        #expect(LocalNotificationProjection.isQuietOrFallback(from: [
            LocalNotificationProjection.deliveryDispositionKey:
                LocalNotificationProjection.fallbackDisposition,
        ]))
        #expect(!LocalNotificationProjection.isQuietOrFallback(from: [:]))
        #expect(LocalNotificationProjection.isActionFailure(from: [
            LocalNotificationProjection.deliveryDispositionKey:
                LocalNotificationProjection.actionFailureDisposition,
        ]))
    }

    @Test func notificationActionsRemoveOnlyTheActedNotification() {
        #expect(
            NotificationActionDeliveredNotificationPolicy.identifiersToRemove(
                actedNotificationIdentifier: "acted"
            ) == ["acted"]
        )
    }

    @Test func groupMessageUsesGroupTitleAndSenderBodyPrefix() {
        withAppLanguage(.english) {
            let update = notificationUpdate(
                isDm: false,
                groupName: " Project\nRoom ",
                senderName: "Bob",
                previewText: "Ship it"
            )

            let presentation = LocalNotificationProjection.makePresentation(for: update)

            #expect(presentation?.title == "Project Room")
            #expect(presentation?.body == "Bob: Ship it")
        }
    }

    @Test func groupReactionNamesEmojiAndReactedToMessage() {
        withAppLanguage(.english) {
            let update = notificationUpdate(
                isDm: false,
                groupName: "Project Room",
                senderName: "Alice",
                previewText: "❤️",
                reactionEmoji: "❤️",
                reactedToPreview: " Lunch at\n1? "
            )

            let presentation = LocalNotificationProjection.makePresentation(for: update)

            #expect(presentation?.title == "Project Room")
            #expect(presentation?.body == "Alice reacted ❤️ to: “Lunch at 1?”")
        }
    }

    @Test func directReactionKeepsSenderInTitle() {
        withAppLanguage(.english) {
            let update = notificationUpdate(
                isDm: true,
                senderName: "Alice",
                previewText: "👍",
                reactionEmoji: "👍",
                reactedToPreview: "Lunch at 1?"
            )

            let presentation = LocalNotificationProjection.makePresentation(for: update)

            #expect(presentation?.title == "Alice")
            #expect(presentation?.body == "Reacted 👍 to: “Lunch at 1?”")
        }
    }

    @Test func reactionWithoutResolvableTargetOmitsQuote() {
        withAppLanguage(.english) {
            let group = notificationUpdate(
                isDm: false,
                groupName: "Project Room",
                senderName: "Alice",
                previewText: "🎉",
                reactionEmoji: "🎉",
                reactedToPreview: nil
            )
            let direct = notificationUpdate(
                isDm: true,
                senderName: "Alice",
                previewText: "🎉",
                reactionEmoji: "🎉",
                reactedToPreview: "  "
            )

            #expect(LocalNotificationProjection.makePresentation(for: group)?.body == "Alice reacted 🎉")
            #expect(LocalNotificationProjection.makePresentation(for: direct)?.body == "Reacted 🎉")
        }
    }

    @Test func reactionEmojiIsSanitizedAndBlankEmojiFallsBackToMessageBody() {
        withAppLanguage(.english) {
            let spoofed = notificationUpdate(
                isDm: false,
                groupName: "Project Room",
                senderName: "Alice",
                previewText: "❤️",
                reactionEmoji: "\u{202E}❤️\u{200B}",
                reactedToPreview: "Lunch"
            )
            let blank = notificationUpdate(
                isDm: false,
                groupName: "Project Room",
                senderName: "Alice",
                previewText: "Hello",
                reactionEmoji: "\u{200B} ",
                reactedToPreview: "Lunch"
            )

            #expect(LocalNotificationProjection.makePresentation(for: spoofed)?.body == "Alice reacted ❤️ to: “Lunch”")
            #expect(LocalNotificationProjection.makePresentation(for: blank)?.body == "Alice: Hello")
        }
    }

    @Test func reactionContentFollowsPreviewMode() {
        withAppLanguage(.english) {
            let update = notificationUpdate(
                isDm: false,
                groupName: "Project Room",
                senderName: "Alice",
                previewText: "❤️",
                reactionEmoji: "❤️",
                reactedToPreview: "Lunch at 1?"
            )

            let senderOnly = LocalNotificationProjection.makePresentation(for: update, previewMode: .senderOnly)
            let generic = LocalNotificationProjection.makePresentation(for: update, previewMode: .generic)

            #expect(senderOnly?.body == "Alice sent a message")
            #expect(generic?.title == "White Noise")
            #expect(generic?.body == "New encrypted message")
        }
    }

    @Test func groupReactionLocalizesBody() {
        withAppLanguage(.french) {
            let update = notificationUpdate(
                isDm: false,
                groupName: "Project Room",
                senderName: "Alice",
                previewText: "❤️",
                reactionEmoji: "❤️",
                reactedToPreview: "Lunch"
            )

            let presentation = LocalNotificationProjection.makePresentation(for: update)

            #expect(presentation?.body == "Alice a réagi avec ❤️ à : « Lunch »")
        }
    }

    @Test func groupMessagePreviewUsesLocalizedSeparator() {
        withAppLanguage(.french) {
            let update = notificationUpdate(
                isDm: false,
                groupName: "Project Room",
                senderName: "Bob",
                previewText: "Ship it"
            )

            let presentation = LocalNotificationProjection.makePresentation(for: update)

            #expect(presentation?.body == "Bob : Ship it")
        }
    }

    @Test func groupMentionUsesMentionBodyPrefix() {
        let update = notificationUpdate(
            isDm: false,
            isMention: true,
            groupName: "Project Room",
            senderName: "Bob",
            previewText: "Ship it"
        )

        let presentation = LocalNotificationProjection.makePresentation(for: update)

        #expect(presentation?.title == "Project Room")
        #expect(presentation?.body == "Bob mentioned you: Ship it")
    }

    @Test func groupMentionWithoutPreviewUsesMentionFallback() {
        let update = notificationUpdate(
            isDm: false,
            isMention: true,
            groupName: nil,
            senderName: "Bob",
            previewText: nil
        )

        let presentation = LocalNotificationProjection.makePresentation(for: update)

        #expect(presentation?.title == "Group message")
        #expect(presentation?.body == "Bob mentioned you")
    }

    @Test func notificationFallbacksUseFormattedLocalizationKeys() {
        let invite = notificationUpdate(
            trigger: .groupInvite,
            isDm: false,
            groupName: "Project Room",
            previewText: nil
        )
        let inviteWithoutGroupName = notificationUpdate(
            trigger: .groupInvite,
            isDm: false,
            groupName: nil,
            previewText: nil
        )
        let groupMessage = notificationUpdate(
            isDm: false,
            groupName: nil,
            senderName: "Bob",
            previewText: nil
        )

        #expect(LocalNotificationProjection.makePresentation(for: invite)?.body == L10n.formatted("Invitation to %@", "Project Room"))
        #expect(LocalNotificationProjection.makePresentation(for: inviteWithoutGroupName)?.body == L10n.string("Open White Noise to view the invite"))
        #expect(LocalNotificationProjection.makePresentation(for: groupMessage)?.body == L10n.formatted("%@ sent a message", "Bob"))
    }

    @Test func groupMembershipAndAdminNotificationsUseDedicatedCopy() {
        let removed = LocalNotificationProjection.makePresentation(for: notificationUpdate(
            trigger: .removedFromGroup,
            isDm: false,
            groupName: "Project Room",
            previewText: nil
        ))
        let madeAdmin = LocalNotificationProjection.makePresentation(for: notificationUpdate(
            trigger: .madeAdmin,
            isDm: false,
            groupName: "Project Room",
            previewText: nil
        ))
        let removedAsAdmin = LocalNotificationProjection.makePresentation(for: notificationUpdate(
            trigger: .removedAsAdmin,
            isDm: false,
            groupName: nil,
            previewText: nil
        ))

        #expect(removed?.title == "Project Room")
        #expect(removed?.body == "You were removed from this chat.")
        #expect(madeAdmin?.title == "Project Room")
        #expect(madeAdmin?.body == "You are now an admin.")
        #expect(removedAsAdmin?.title == "White Noise")
        #expect(removedAsAdmin?.body == "You are no longer an admin.")
    }

    @Test func selfMessagesAreNotPresentedLocally() {
        let update = notificationUpdate(isFromSelf: true)

        #expect(LocalNotificationProjection.makePresentation(for: update) == nil)
    }

    @Test func tapRouteRoundTripsThroughUserInfo() {
        let route = LocalNotificationRoute(
            accountRef: "account-b",
            groupIdHex: "group-b",
            notificationKey: "notif-b",
            messageIdHex: "message-b"
        )

        let parsed = LocalNotificationProjection.route(from: LocalNotificationProjection.userInfo(for: route))

        #expect(parsed == route)
    }

    @Test func missingPreviewFallsBackToGenericEncryptedMessage() {
        let update = notificationUpdate(isDm: true, senderName: nil, previewText: nil)

        let presentation = LocalNotificationProjection.makePresentation(for: update)

        #expect(
            presentation?.title
                == IdentityPresentation.text(
                    accountIdHex: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
                )
        )
        #expect(presentation?.body == "New encrypted message")
    }
}
