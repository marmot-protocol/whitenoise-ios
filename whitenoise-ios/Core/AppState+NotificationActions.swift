import Foundation
import MarmotKit
import UIKit

/// Reserves time for SQLCipher storage closure before UIKit's background
/// expiration fires, refusing to open a new background runtime when the
/// remaining system window cannot fit both work and teardown.
nonisolated enum NotificationActionBackgroundBudget {
    enum Context: Equatable {
        /// A UI scene has reported `.active`.
        case foreground
        /// A UI scene entered `.background` (where UIKit documents
        /// `UIApplication.backgroundTimeRemaining` as a valid countdown).
        case background
        /// Cold UI-less launch (`!sceneHasReportedPhase`), where UIKit does not
        /// guarantee a finite `backgroundTimeRemaining` countdown.
        case coldBackgroundLaunch
    }

    static let storageCloseReserveSeconds: TimeInterval = 6
    static let minimumWorkSeconds: TimeInterval = 1
    /// Conservative cap for cold UI-less launches where UIKit can report
    /// `DBL_MAX` even though the system grants roughly 25–30 seconds total.
    static let coldLaunchMaximumWorkSeconds: TimeInterval = 18

    /// Returns the effective deadline for a notification action, or `nil` when
    /// remaining background time is too short to safely open and close storage.
    static func effectiveDeadline(
        requested: Duration,
        backgroundTimeRemaining: TimeInterval,
        context: Context
    ) -> Duration? {
        let requestedSeconds = durationSeconds(requested)
        guard requestedSeconds > 0 else { return nil }
        switch context {
        case .foreground:
            return requested
        case .background:
            return boundedBackgroundDeadline(
                requested: requested,
                backgroundTimeRemaining: backgroundTimeRemaining
            )
        case .coldBackgroundLaunch:
            let cappedDuration: Duration = coldLaunchMaximumWorkSeconds < requestedSeconds
                ? .seconds(coldLaunchMaximumWorkSeconds)
                : requested
            return boundedBackgroundDeadline(
                requested: cappedDuration,
                backgroundTimeRemaining: backgroundTimeRemaining
            )
        }
    }

    /// True when UIKit reports an unbounded positive `backgroundTimeRemaining`
    /// (`DBL_MAX` / `.greatestFiniteMagnitude` or `.infinity`) rather than a
    /// real countdown.
    static func isUnboundedBackgroundTimeRemaining(_ backgroundTimeRemaining: TimeInterval) -> Bool {
        guard !backgroundTimeRemaining.isNaN, backgroundTimeRemaining > 0 else { return false }
        return !backgroundTimeRemaining.isFinite
            || backgroundTimeRemaining >= TimeInterval.greatestFiniteMagnitude / 2
    }

    /// Clamps `requested` to the remaining background-batch budget before
    /// `cutoff`, or returns `nil` when less than `minimumWorkSeconds` remains.
    static func remainingBackgroundBatchWorkDeadline(
        requested: Duration,
        now: ContinuousClock.Instant,
        cutoff: ContinuousClock.Instant
    ) -> Duration? {
        let remaining = now.duration(to: cutoff)
        guard remaining >= .seconds(minimumWorkSeconds) else { return nil }
        return min(requested, remaining)
    }

    private static func boundedBackgroundDeadline(
        requested: Duration,
        backgroundTimeRemaining: TimeInterval
    ) -> Duration? {
        let requestedSeconds = durationSeconds(requested)
        guard requestedSeconds > 0, !backgroundTimeRemaining.isNaN else { return nil }
        guard backgroundTimeRemaining.isFinite else {
            return backgroundTimeRemaining > 0 ? requested : nil
        }
        // Compare in TimeInterval seconds before calling `Duration.seconds(...)`
        // so `TimeInterval.greatestFiniteMagnitude` never traps on Int64 overflow.
        if backgroundTimeRemaining >= requestedSeconds + storageCloseReserveSeconds {
            return requested
        }
        let availableForWork = backgroundTimeRemaining - storageCloseReserveSeconds
        guard availableForWork >= minimumWorkSeconds else { return nil }
        return .seconds(availableForWork)
    }

    private static func durationSeconds(_ duration: Duration) -> TimeInterval {
        TimeInterval(duration.components.seconds)
            + TimeInterval(duration.components.attoseconds) / 1e18
    }
}

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
    /// suspended or on a cold UI-less launch — a lease-owned frozen ephemeral
    /// runtime that is shut down when the action completes, leaving the durable
    /// runtime untouched. Either way the work is held open by the same
    /// idempotent UIKit background-task helper the suspension path uses.
    @MainActor
    func performNotificationAction(
        _ operation: NotificationActionOperation,
        backgroundBatchCutoff: ContinuousClock.Instant? = nil,
        now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }
    ) async {
        guard !blocksAccountWork else { return }
        switch operation {
        case .openChat(let route):
            presentNotification(route: route)
        case .reply(let route, let text):
            await runNotificationAction(
                route: route,
                failureTitle: L10n.string("Reply not sent"),
                backgroundBatchCutoff: backgroundBatchCutoff,
                now: now
            ) { [notifications] client, markSucceeded in
                _ = try await client.sendText(
                    accountRef: route.accountRef,
                    groupIdHex: route.groupIdHex,
                    text: text
                )
                markSucceeded()
                // Replying implies the notified message was read. Best-effort:
                // a failed or timed-out follow-up must not report the delivered
                // reply as failed.
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
        case .rejectedReply(let route):
            let notice = ConversationSendRecovery.notice(for: .text, restored: true)
            await notifications.presentNotificationActionFailure(
                title: notice.title,
                body: notice.message,
                route: route
            )
        case .markRead(let route, let messageIdHex):
            await runNotificationAction(
                route: route,
                failureTitle: L10n.string("Couldn't mark as read"),
                backgroundBatchCutoff: backgroundBatchCutoff,
                now: now
            ) { [notifications] client, markSucceeded in
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
                markSucceeded()
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
        backgroundBatchCutoff: ContinuousClock.Instant? = nil,
        now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
        deadlineSleeper: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        backgroundTimeRemaining: @escaping @MainActor () -> TimeInterval = {
            UIApplication.shared.backgroundTimeRemaining
        },
        makeBackgroundTask: @MainActor (
            _ name: String,
            _ onExpiration: @escaping @MainActor () -> Void
        ) -> BackgroundRuntimeSuspensionTask = { name, onExpiration in
            BackgroundRuntimeSuspensionTask(name: name, onExpiration: onExpiration)
        },
        perform: @escaping @MainActor (MarmotClient, @escaping @MainActor () -> Void) async throws -> Void
    ) async {
        guard !blocksAccountWork else { return }
        let actionID = UUID()
        let actionStartedAt = now()
        let gate = NotificationActionDeadlineGate()
        let backgroundTask = makeBackgroundTask("Notification action") {
            gate.resolve(.expired)
        }
        // Only a UI scene that has actually reported `.active` may proceed
        // without a background assertion; on a cold UI-less launch
        // `isAppSceneActive` still holds its optimistic initial `true` while
        // `sceneHasReportedPhase` is false.
        let budgetContext: NotificationActionBackgroundBudget.Context = if !sceneHasReportedPhase {
            .coldBackgroundLaunch
        } else if hasReportedActiveScene {
            .foreground
        } else {
            .background
        }
        let remainingBackgroundTime = backgroundTimeRemaining()
        let usesSharedFallbackCutoff = budgetContext == .coldBackgroundLaunch
            || (budgetContext == .background
                && NotificationActionBackgroundBudget.isUnboundedBackgroundTimeRemaining(
                    remainingBackgroundTime
                ))
        let requestedDeadline: Duration? = if usesSharedFallbackCutoff,
                                              let backgroundBatchCutoff {
            NotificationActionBackgroundBudget.remainingBackgroundBatchWorkDeadline(
                requested: deadline,
                now: actionStartedAt,
                cutoff: backgroundBatchCutoff
            )
        } else {
            deadline
        }
        guard budgetContext == .foreground || backgroundTask.isActive,
              let requestedDeadline,
              let effectiveDeadline = NotificationActionBackgroundBudget.effectiveDeadline(
                  requested: requestedDeadline,
                  backgroundTimeRemaining: remainingBackgroundTime,
                  context: budgetContext
              )
        else {
            backgroundTask.endIfNeeded()
            await notifications.presentNotificationActionFailure(
                title: failureTitle,
                body: L10n.string("Open the chat to try again."),
                route: route
            )
            return
        }
        // Record operation success as soon as the core mutation commits (and
        // before runtime teardown) so a deadline firing during post-mutation
        // follow-up or cold storage close drains cleanly without falsely
        // reporting "Reply not sent" after a delivered reply.
        var performSucceeded = false
        let actionTask = Task { @MainActor [weak self] in
            guard let self else {
                gate.resolve(.completed(succeeded: false))
                return
            }
            await self.runNotificationActionAgainstRuntime(
                actionID: actionID,
                markSucceeded: { performSucceeded = true },
                perform: perform
            )
            gate.resolve(.completed(succeeded: performSucceeded))
        }
        func makeDeadlineTask(for duration: Duration) -> Task<Void, Never> {
            Task { @MainActor in
                do {
                    try await deadlineSleeper(duration)
                    gate.resolve(.expired)
                } catch {
                    // Normal completion or budget tightening cancels the deadline.
                }
            }
        }
        var currentDeadlineInstant = actionStartedAt.advanced(by: effectiveDeadline)
        var deadlineTask = makeDeadlineTask(for: effectiveDeadline)
        // If the app enters `.background` while the action is running (e.g.
        // with an invalid foreground assertion or a short background grant),
        // re-evaluate against UIKit's now-valid `backgroundTimeRemaining` so
        // SQLCipher closes proactively before UIKit suspends the process.
        // Tightening is strictly monotonic: never extend an already-tighter
        // deadline (such as the cold-launch cap).
        runtimeLifecycle.setNotificationActionBackgroundEntryHandler(actionID: actionID) {
            guard backgroundTask.isActive else {
                deadlineTask.cancel()
                gate.resolve(.expired)
                return
            }
            let currentInstant = now()
            let remainingCurrent = currentInstant.duration(to: currentDeadlineInstant)
            guard remainingCurrent > .zero,
                  let tightenedDeadline = NotificationActionBackgroundBudget.effectiveDeadline(
                      requested: remainingCurrent,
                      backgroundTimeRemaining: backgroundTimeRemaining(),
                      context: .background
                  )
            else {
                deadlineTask.cancel()
                gate.resolve(.expired)
                return
            }
            let candidateInstant = currentInstant.advanced(by: tightenedDeadline)
            guard candidateInstant < currentDeadlineInstant else { return }
            currentDeadlineInstant = candidateInstant
            deadlineTask.cancel()
            deadlineTask = makeDeadlineTask(for: tightenedDeadline)
        }
        defer {
            runtimeLifecycle.clearNotificationActionBackgroundEntryHandler(actionID: actionID)
        }
        let succeeded: Bool
        switch await gate.wait() {
        case .completed(let actionSucceeded):
            succeeded = actionSucceeded
        case .expired:
            actionTask.cancel()
            await runtimeLifecycle.expireActiveNotificationAction(actionID: actionID)
            succeeded = performSucceeded
        }
        deadlineTask.cancel()
        backgroundTask.endIfNeeded()

        if !succeeded, !blocksAccountWork {
            await notifications.presentNotificationActionFailure(
                title: failureTitle,
                body: L10n.string("Open the chat to try again."),
                route: route
            )
        }
    }

    @MainActor
    private func runNotificationActionAgainstRuntime(
        actionID: UUID,
        markSucceeded: @escaping @MainActor () -> Void,
        perform: @MainActor (MarmotClient, @escaping @MainActor () -> Void) async throws -> Void
    ) async {
        guard !blocksAccountWork else { return }
        do {
            let lease = try await runtimeLifecycle.startRuntimeForNotificationAction(actionID: actionID)
            do {
                try await perform(lease.client, markSucceeded)
                markSucceeded()
            } catch {
                // `performSucceeded` already reflects whether the core mutation committed.
            }
            await runtimeLifecycle.suspendRuntimeAfterNotificationAction(lease)
        } catch {
            // Runtime could not be leased; `performSucceeded` remains false.
        }
    }
}
