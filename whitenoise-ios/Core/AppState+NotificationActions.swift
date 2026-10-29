import Foundation
import MarmotKit

/// Settles a notification action once: whichever of completion, the deadline
/// or UIKit's background expiration resolves first wins.
@MainActor
final class NotificationActionDeadlineGate {
    enum Outcome: Equatable {
        case completed(succeeded: Bool)
        case expired
    }

    private var outcome: Outcome?
    private var continuation: CheckedContinuation<Outcome, Never>?

    func resolve(_ outcome: Outcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        continuation?.resume(returning: outcome)
        continuation = nil
    }

    func wait() async -> Outcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation in
            if let outcome {
                continuation.resume(returning: outcome)
            } else {
                self.continuation = continuation
            }
        }
    }
}

extension AppState {
    /// Executes a notification-action response. Reply and mark-read run against
    /// a runtime leased for the action: the live foreground runtime when the app
    /// is active, or — when it arrives while backgrounded with the runtime
    /// suspended — a lease-owned frozen ephemeral runtime that is shut down when
    /// the action completes, leaving the durable runtime suspended. Either way
    /// the work is held open by the same idempotent UIKit background-task helper
    /// the suspension path uses.
    @MainActor
    func performNotificationAction(_ operation: NotificationActionOperation) async {
        switch operation {
        case .openChat(let route):
            presentNotification(route: route)
        case .reply(let route, let text):
            await runNotificationAction(
                route: route,
                failureTitle: L10n.string("Reply not sent")
            ) { [notifications] client in
                _ = try await client.sendText(
                    accountRef: route.accountRef,
                    groupIdHex: route.groupIdHex,
                    text: text
                )
                // Replying implies the notified message was read. Best-effort:
                // a failed mark must not report the delivered reply as failed.
                if let messageIdHex = route.messageIdHex, !messageIdHex.isEmpty {
                    // The read cursor only advances for an initialized chat —
                    // the conversation screen normally does this on open.
                    _ = try? await client.initializeChatReadState(
                        accountRef: route.accountRef,
                        groupIdHex: route.groupIdHex
                    )
                    let results = await client.markTimelineMessagesRead(
                        accountRef: route.accountRef,
                        groupIdHex: route.groupIdHex,
                        messageIdHexes: [messageIdHex]
                    )
                    if results.contains(where: \.succeeded) {
                        await notifications.reconcileDeliveredNotificationsAfterRead(
                            accountRef: route.accountRef,
                            groupIdHex: route.groupIdHex,
                            readMessageIdHexes: [messageIdHex],
                            conversationStillHasUnread: results.compactMap(\.row).last?.hasUnread
                        )
                    }
                }
                // Preserve the exact-action fallback for older deliveries that
                // lack enough metadata for conversation-level reconciliation.
                notifications.removeDeliveredNotification(identifier: route.notificationKey)
                await self.refreshAccountUnreadSummaries(using: client)
            }
        case .markRead(let route, let messageIdHex):
            await runNotificationAction(
                route: route,
                failureTitle: L10n.string("Couldn't mark as read")
            ) { [notifications] client in
                // The read cursor only advances for an initialized chat — the
                // conversation screen normally does this on open.
                _ = try? await client.initializeChatReadState(
                    accountRef: route.accountRef,
                    groupIdHex: route.groupIdHex
                )
                let results = await client.markTimelineMessagesRead(
                    accountRef: route.accountRef,
                    groupIdHex: route.groupIdHex,
                    messageIdHexes: [messageIdHex]
                )
                guard results.contains(where: \.succeeded) else {
                    throw NotificationActionError.markReadFailed
                }
                await notifications.reconcileDeliveredNotificationsAfterRead(
                    accountRef: route.accountRef,
                    groupIdHex: route.groupIdHex,
                    readMessageIdHexes: [messageIdHex],
                    conversationStillHasUnread: results.compactMap(\.row).last?.hasUnread
                )
                notifications.removeDeliveredNotification(identifier: route.notificationKey)
                await self.refreshAccountUnreadSummaries(using: client)
            }
        }
    }

    @MainActor
    func runNotificationAction(
        route: LocalNotificationRoute,
        failureTitle: String,
        deadline: Duration = .seconds(20),
        perform: @escaping @MainActor (MarmotClient) async throws -> Void
    ) async {
        let gate = NotificationActionDeadlineGate()
        let backgroundTask = BackgroundRuntimeSuspensionTask(
            name: "Notification action",
            onExpiration: { gate.resolve(.expired) }
        )
        let actionTask = Task { @MainActor [weak self] in
            guard let self else {
                gate.resolve(.completed(succeeded: false))
                return
            }
            let succeeded = await self.runNotificationActionAgainstRuntime(
                route: route,
                perform: perform
            )
            gate.resolve(.completed(succeeded: succeeded))
        }
        let deadlineTask = Task { @MainActor in
            do {
                try await Task.sleep(for: deadline)
                gate.resolve(.expired)
            } catch {
                // Normal completion cancels the deadline.
            }
        }
        let succeeded: Bool
        switch await gate.wait() {
        case .completed(let actionSucceeded):
            succeeded = actionSucceeded
        case .expired:
            actionTask.cancel()
            await runtimeLifecycle.expireActiveNotificationAction()
            succeeded = false
        }
        deadlineTask.cancel()
        backgroundTask.endIfNeeded()

        if !succeeded {
            await notifications.presentNotificationActionFailure(
                title: failureTitle,
                body: L10n.string("Open the chat to try again."),
                route: route
            )
        }
    }

    @MainActor
    private func runNotificationActionAgainstRuntime(
        route: LocalNotificationRoute,
        perform: @MainActor (MarmotClient) async throws -> Void
    ) async -> Bool {
        // A cold background launch can deliver the response while bootstrap is
        // still bringing the runtime up; ride the existing bootstrap instead of
        // racing it.
        if phase == .bootstrapping {
            await bootstrap()
        }
        do {
            let lease = try await runtimeLifecycle.startRuntimeForNotificationAction()
            var succeeded = true
            do {
                try await perform(lease.client)
            } catch {
                succeeded = false
            }
            await runtimeLifecycle.suspendRuntimeAfterNotificationAction(lease)
            return succeeded
        } catch {
            return false
        }
    }
}
