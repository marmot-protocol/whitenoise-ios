import Foundation
import Testing
import UserNotifications
import MarmotKit
import Synchronization
@testable import whitenoise_ios

@MainActor
struct NotificationActionRoutingTests {
    private let route = LocalNotificationRoute(
        accountRef: "account-a",
        groupIdHex: "group-a",
        notificationKey: "notif-a",
        messageIdHex: "message-a"
    )

    private let routeWithoutMessageId = LocalNotificationRoute(
        accountRef: "account-a",
        groupIdHex: "group-a",
        notificationKey: "notif-a",
        messageIdHex: nil
    )

    @Test func defaultTapRoutesToOpenChat() {
        let operation = NotificationActionRouting.operation(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userText: nil,
            route: route
        )
        #expect(operation == .openChat(route))
    }

    @Test func replyActionCarriesTrimmedText() {
        let operation = NotificationActionRouting.operation(
            actionIdentifier: NotificationActionCategory.replyActionIdentifier,
            userText: "  hello there \n",
            route: route
        )
        #expect(operation == .reply(route, text: "hello there"))
    }

    @Test func replyActionWithWhitespaceOnlyTextIsDropped() {
        let operation = NotificationActionRouting.operation(
            actionIdentifier: NotificationActionCategory.replyActionIdentifier,
            userText: "  \n\t ",
            route: route
        )
        #expect(operation == nil)
    }

    @Test func replyActionWithNilTextIsDropped() {
        let operation = NotificationActionRouting.operation(
            actionIdentifier: NotificationActionCategory.replyActionIdentifier,
            userText: nil,
            route: route
        )
        #expect(operation == nil)
    }

    @Test func replyOverProtocolMaxLengthIsRejectedInsteadOfShortened() {
        let oversized = String(repeating: "x", count: ContentSanitizer.maxMessageLength + 1)
        let operation = NotificationActionRouting.operation(
            actionIdentifier: NotificationActionCategory.replyActionIdentifier,
            userText: oversized,
            route: route
        )
        #expect(operation == .rejectedReply(route))
    }

    @Test func replyAtProtocolMaxLengthIsSentWhole() {
        let exact = String(repeating: "x", count: ContentSanitizer.maxMessageLength)
        let operation = NotificationActionRouting.operation(
            actionIdentifier: NotificationActionCategory.replyActionIdentifier,
            userText: exact,
            route: route
        )
        #expect(operation == .reply(route, text: exact))
    }

    /// #1276: an over-limit reply sends nothing and starts no runtime, and is
    /// reported with the same notice as any reply that failed to send.
    @Test func rejectedReplyIsReportedAsUnsentWithoutStartingARuntime() async throws {
        var scheduled: [UNNotificationRequest] = []
        let runtimeRequests = Mutex(0)
        let appState = AppState.test(
            notifications: AppNotifications(notificationRequestScheduler: { scheduled.append($0) }),
            runtimeClientFactory: { _, _, _, _ in
                runtimeRequests.withLock { $0 += 1 }
                throw NotificationActionError.runtimeUnavailable
            }
        )

        await appState.performNotificationAction(.rejectedReply(route))

        let request = try #require(scheduled.first)
        #expect(scheduled.count == 1)
        #expect(request.content.title == L10n.string("Reply not sent"))
        #expect(request.content.body == L10n.string("Open the chat to try again."))
        #expect(runtimeRequests.withLock { $0 } == 0)
    }

    @Test func markReadActionTargetsTheNotifiedMessage() {
        let operation = NotificationActionRouting.operation(
            actionIdentifier: NotificationActionCategory.markReadActionIdentifier,
            userText: nil,
            route: route
        )
        #expect(operation == .markRead(route, messageIdHex: "message-a"))
    }

    @Test func markReadWithoutMessageIdIsDropped() {
        let operation = NotificationActionRouting.operation(
            actionIdentifier: NotificationActionCategory.markReadActionIdentifier,
            userText: nil,
            route: routeWithoutMessageId
        )
        #expect(operation == nil)
    }

    @Test func dismissAndUnknownActionsAreDropped() {
        #expect(NotificationActionRouting.operation(
            actionIdentifier: UNNotificationDismissActionIdentifier,
            userText: nil,
            route: route
        ) == nil)
        #expect(NotificationActionRouting.operation(
            actionIdentifier: "some-unknown-action",
            userText: "hello",
            route: route
        ) == nil)
    }
}

@MainActor
struct NotificationActionCategoryTests {
    @Test func newMessageWithMessageIdGetsMessageCategory() {
        #expect(NotificationActionCategory.identifier(
            trigger: .newMessage,
            messageIdHex: "message-a"
        ) == NotificationActionCategory.message)
    }

    @Test func newMessageWithoutMessageIdGetsNoCategory() {
        #expect(NotificationActionCategory.identifier(trigger: .newMessage, messageIdHex: nil) == nil)
        #expect(NotificationActionCategory.identifier(trigger: .newMessage, messageIdHex: "") == nil)
    }

    @Test func groupInviteGetsNoCategory() {
        #expect(NotificationActionCategory.identifier(
            trigger: .groupInvite,
            messageIdHex: "message-a"
        ) == nil)
    }

    @Test func groupStateUpdatesGetNoMessageActions() {
        #expect(NotificationActionCategory.identifier(
            trigger: .removedFromGroup,
            messageIdHex: "message-a"
        ) == nil)
        #expect(NotificationActionCategory.identifier(
            trigger: .madeAdmin,
            messageIdHex: "message-a"
        ) == nil)
        #expect(NotificationActionCategory.identifier(
            trigger: .removedAsAdmin,
            messageIdHex: "message-a"
        ) == nil)
    }

    @Test func projectionStampsMessageCategoryOnMessagePresentations() {
        let presentation = LocalNotificationProjection.makePresentation(for: actionTestUpdate())
        #expect(presentation?.categoryIdentifier == NotificationActionCategory.message)
    }

    @Test func projectionDoesNotExposeGiphyMediaURLInNotificationBody() {
        let update = actionTestUpdate(
            previewText: "https://media.giphy.com/media/abc/giphy.mp4?cid=client&rid=giphy.mp4\nvia GIPHY · Creator"
        )

        let presentation = LocalNotificationProjection.makePresentation(for: update)

        #expect(presentation?.body == "Alice: GIF via GIPHY")
    }

    @Test func projectionLeavesInvitePresentationsActionFree() {
        let presentation = LocalNotificationProjection.makePresentation(
            for: actionTestUpdate(trigger: .groupInvite, messageIdHex: nil)
        )
        #expect(presentation?.categoryIdentifier == nil)
    }

    @Test func summaryPresentationsStayActionFree() throws {
        let base = try #require(LocalNotificationProjection.makePresentation(for: actionTestUpdate()))
        let summary = NotificationPresentationPolicy.summaryPresentation(
            after: base,
            overflowCount: 3,
            containsMention: false
        )
        #expect(summary.categoryIdentifier == nil)
    }

    @Test func decoratorAppliesCategoryToContent() throws {
        let presentation = try #require(
            LocalNotificationProjection.makePresentation(for: actionTestUpdate())
        )
        let content = NotificationContentDecorator.makeContent(for: presentation)
        #expect(content.categoryIdentifier == NotificationActionCategory.message)
    }

    @Test func decoratorLeavesCategoryEmptyForActionFreePresentations() throws {
        var presentation = try #require(
            LocalNotificationProjection.makePresentation(for: actionTestUpdate())
        )
        presentation.categoryIdentifier = nil
        let content = NotificationContentDecorator.makeContent(for: presentation)
        #expect(content.categoryIdentifier.isEmpty)
    }

    @Test func registeredCategoryWiresReplyAndMarkReadActions() {
        let category = AppNotifications.messageNotificationCategory()
        #expect(category.identifier == NotificationActionCategory.message)
        #expect(category.actions.map(\.identifier) == [
            NotificationActionCategory.replyActionIdentifier,
            NotificationActionCategory.markReadActionIdentifier,
        ])
        #expect(category.actions.first is UNTextInputNotificationAction)
        // Neither action should foreground the app; both run in the background.
        #expect(category.actions.allSatisfy { !$0.options.contains(.foreground) })
    }
}

private func actionTestUpdate(
    trigger: NotificationTriggerFfi = .newMessage,
    messageIdHex: String? = "message-a",
    previewText: String = "Hello"
) -> NotificationUpdateFfi {
    NotificationUpdateFfi(
        notificationKey: "notif-a",
        conversationKey: "conv-a",
        trigger: trigger,
        accountRef: "account-a",
        accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
        groupIdHex: "group-a",
        groupName: "Group A",
        isDm: false,
        isMention: false,
        messageIdHex: messageIdHex,
        sender: NotificationUserFfi(
            accountIdHex: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            displayName: "Alice",
            pictureUrl: nil
        ),
        receiver: NotificationUserFfi(
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            displayName: "Me",
            pictureUrl: nil
        ),
        previewText: previewText,
        reactionEmoji: nil,
        reactedToPreview: nil,
        timestampMs: 1_700_000_000_123,
        isFromSelf: false
    )
}
