import Foundation
import Testing
import MarmotKit
import UserNotifications
@testable import whitenoise_ios

struct ForegroundNotificationBatchTests {
    private func presentation(_ message: String, account: String = "a", group: String = "g", mention: Bool = false) -> LocalNotificationPresentation {
        let route = LocalNotificationRoute(accountRef: account, groupIdHex: group, notificationKey: message, messageIdHex: message)
        var info = LocalNotificationProjection.userInfo(for: route)
        info[LocalNotificationProjection.isMentionKey] = mention ? "1" : "0"
        return LocalNotificationPresentation(identifier: message, threadIdentifier: group, title: "Group", body: "Hello",
            route: route, timestamp: .distantPast, userInfo: info, categoryIdentifier: NotificationActionCategory.message,
            senderName: "Alice", senderAccountIdHex: "alice", senderPictureUrl: "https://example.com/a.png")
    }

    @Test func burstKeepsFirstDeadlineAndUsesOneConversationIdentifier() {
        var batch = ForegroundNotificationBatch()
        let first = batch.schedule(presentation("1"), now: 10, previewMode: .senderAndMessage)
        let last = batch.schedule(presentation("2", mention: true), now: 11.5, previewMode: .senderAndMessage)
        #expect(first.delay == 2)
        #expect(last.delay == 0.5)
        #expect(first.presentation.identifier == last.presentation.identifier)
        #expect(last.presentation.body == L10n.plural("%lld new messages", Int64(2)))
        #expect(last.presentation.route.messageIdHex == "2")
        #expect(last.presentation.route.notificationKey == last.presentation.identifier)
        #expect(last.presentation.senderPictureUrl == nil)
        #expect(LocalNotificationProjection.isMention(from: last.presentation.userInfo))
        let next = batch.schedule(presentation("3"), now: 12.1, previewMode: .senderAndMessage)
        #expect(next.delay == 2)
        #expect(next.presentation.identifier == first.presentation.identifier)
        #expect(next.presentation.body == "Hello")
    }

    @Test func accountsAndGroupsAreIsolatedAndDuplicatesDoNotInflateCount() {
        var batch = ForegroundNotificationBatch()
        let first = batch.schedule(presentation("1"), now: 0, previewMode: .senderOnly)
        let duplicate = batch.schedule(presentation("1"), now: 1, previewMode: .senderOnly)
        let otherAccount = batch.schedule(presentation("1", account: "b"), now: 1, previewMode: .senderOnly)
        let otherGroup = batch.schedule(presentation("1", group: "h"), now: 1, previewMode: .senderOnly)
        #expect(duplicate.presentation.body == "Hello")
        #expect(Set([first.presentation.identifier, otherAccount.presentation.identifier, otherGroup.presentation.identifier]).count == 3)
        #expect(otherAccount.delay == 2)
    }

    @Test func genericBatchDoesNotRevealCountOrSenderAndReadCleanupPreservesNewerMessages() {
        var batch = ForegroundNotificationBatch()
        var generic = presentation("1")
        generic.senderName = nil
        generic.senderAccountIdHex = nil
        generic.senderPictureUrl = nil
        _ = batch.schedule(generic, now: 0, previewMode: .generic)
        let latest = batch.schedule(presentation("2"), now: 1, previewMode: .generic)
        #expect(latest.presentation.body == "Hello")
        #expect(latest.presentation.senderName == nil)
        #expect(batch.cancel(account: "a", group: "g", readMessages: ["1"]).isEmpty)
        #expect(batch.cancel(account: "a", group: "g", readMessages: ["2"]) == [latest.presentation.identifier])
        #expect(batch.schedule(presentation("3"), now: 1.5, previewMode: .senderOnly).delay == 2)
        #expect(batch.cancel(account: "a").count == 1)
    }

    @Test func delayedOlderUpdateDoesNotMoveTheReadTargetBackwards() {
        var batch = ForegroundNotificationBatch()
        let older = presentation("older")
        let newer = LocalNotificationPresentation(identifier: "newer", threadIdentifier: "g", title: "Group", body: "Latest",
            route: LocalNotificationRoute(accountRef: "a", groupIdHex: "g", notificationKey: "newer", messageIdHex: "newer"),
            timestamp: .distantFuture, userInfo: [:])
        _ = batch.schedule(newer, now: 0, previewMode: .senderOnly)
        let plan = batch.schedule(older, now: 1, previewMode: .senderOnly)
        #expect(plan.presentation.route.messageIdHex == "newer")
        #expect(batch.cancel(account: "a", readMessages: ["older"]).isEmpty)
        #expect(batch.cancel().count == 1)
    }

    @Test func overflowIsImmediateAndStateRemainsBounded() {
        var batch = ForegroundNotificationBatch()
        for index in 0..<ForegroundNotificationBatch.maximumConversations {
            #expect(batch.schedule(presentation("1", group: String(index)), now: 0, previewMode: .generic).delay == 2)
        }
        #expect(batch.schedule(presentation("1", group: "overflow"), now: 0, previewMode: .generic).delay == 0)
        #expect(batch.cancel(account: "a").count == ForegroundNotificationBatch.maximumConversations)
    }
}

@MainActor
struct ForegroundNotificationSchedulingTests {
    @Test func mainAppSchedulesMessagesButLeavesInvitesImmediate() async {
        var requests: [UNNotificationRequest] = []
        var now: TimeInterval = 10
        let notifications = AppNotifications(notificationRequestScheduler: { requests.append($0) }, notificationClock: { now })
        func update(_ key: String, trigger: NotificationTriggerFfi = .newMessage) -> NotificationUpdateFfi {
            NotificationUpdateFfi(notificationKey: key, conversationKey: "chat", trigger: trigger,
                accountRef: "account", accountIdHex: "owner", groupIdHex: "group", groupName: "Group", isDm: false,
                isMention: false, messageIdHex: key,
                sender: NotificationUserFfi(accountIdHex: "sender", displayName: "Alice", pictureUrl: nil),
                receiver: NotificationUserFfi(accountIdHex: "owner", displayName: "Me", pictureUrl: nil),
                previewText: "Hi", reactionEmoji: nil, reactedToPreview: nil, timestampMs: 1, isFromSelf: false)
        }
        await notifications.present(update: update("1"))
        now = 11.5
        await notifications.present(update: update("2"))
        await notifications.present(update: update("invite", trigger: .groupInvite))
        #expect(requests.count == 3)
        #expect(requests[0].identifier == requests[1].identifier)
        #expect((requests[0].trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval == 2)
        #expect((requests[1].trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval == 0.5)
        #expect(requests[2].trigger == nil)
        #expect(requests[2].identifier == "invite")
        #expect(LocalNotificationProjection.route(from: requests[1].content.userInfo)?.messageIdHex == "2")
    }
}
