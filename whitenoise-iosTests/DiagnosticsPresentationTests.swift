import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

struct DiagnosticsPresentationTests {
    @Test func performanceOperationTextReportsAggregateLatencyShape() throws {
        let snapshot = AppPerformanceOperationSnapshotFfi(
            attempts: 3,
            successes: 2,
            failures: 1,
            durationMs: DurationHistogramSnapshotFfi(
                buckets: [DurationHistogramBucketFfi(upperBoundMs: 250, count: 2)],
                overflowCount: 1,
                sumMs: 875
            )
        )

        let text = try #require(DiagnosticsView.performanceOperationText(
            label: "message send",
            snapshot: snapshot
        ))

        #expect(
            text == "[perf] message send: 3 attempts, 2 succeeded, 1 failed, 875 ms total, 291 ms avg, p50 ≤250 ms, p95 >250 ms"
        )
        #expect(DiagnosticsView.performanceOperationText(
            label: "unused",
            snapshot: AppPerformanceOperationSnapshotFfi(
                attempts: 0,
                successes: 0,
                failures: 0,
                durationMs: DurationHistogramSnapshotFfi(
                    buckets: [],
                    overflowCount: 0,
                    sumMs: 0
                )
            )
        ) == nil)
    }

    @Test func performancePercentilesHandleEmptyAndOverflowOnlyHistograms() {
        #expect(DiagnosticsView.percentileText(
            DurationHistogramSnapshotFfi(buckets: [], overflowCount: 0, sumMs: 0),
            percentile: 0.95
        ) == "n/a")
        #expect(DiagnosticsView.percentileText(
            DurationHistogramSnapshotFfi(buckets: [], overflowCount: 2, sumMs: 4_000),
            percentile: 0.50
        ) == "overflow")
    }

    @Test func diagnosticSelfSendReusesStoredGroupOnlyWhenPresentForAccount() throws {
        let suiteName = "DiagnosticSelfSendTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let storedGroupId = hex("ab")
        let otherGroupId = hex("cd")
        DiagnosticSelfSend.remember(
            groupIdHex: storedGroupId,
            accountRef: "alice",
            defaults: defaults
        )
        let stored = chatListRow(
            groupIdHex: storedGroupId,
            archived: true,
            title: DiagnosticSelfSend.groupName
        )
        let other = chatListRow(
            groupIdHex: otherGroupId,
            archived: true,
            title: DiagnosticSelfSend.groupName
        )

        #expect(
            DiagnosticSelfSend.reusableGroup(
                accountRef: "alice",
                rows: [other, stored],
                defaults: defaults
            )?.groupIdHex == storedGroupId
        )
        #expect(
            DiagnosticSelfSend.reusableGroup(
                accountRef: "alice",
                rows: [other],
                defaults: defaults
            ) == nil
        )
        #expect(
            DiagnosticSelfSend.reusableGroup(
                accountRef: "bob",
                rows: [stored],
                defaults: defaults
            ) == nil
        )
    }

    @Test func diagnosticSelfSendUsesStableNeutralGroupName() {
        #expect(DiagnosticSelfSend.groupName == "Self check")
        #expect(!DiagnosticSelfSend.groupName.localizedCaseInsensitiveContains("diagnostic"))
        #expect(!DiagnosticSelfSend.groupName.contains("-"))
    }

    @Test func messageReceivedDiagnosticRedactsPlaintextButKeepsEventShape() {
        let secret = "secret launch code"
        let sender = hex("11")
        let event = MarmotEventFfi.messageReceived(
            received: RuntimeMessageReceivedFfi(
                accountIdHex: hex("aa"),
                accountLabel: "alice",
                message: ReceivedMessageFfi(
                    messageIdHex: hex("bb"),
                    groupIdHex: hex("cc"),
                    sender: sender,
                    senderDisplayName: nil,
                    plaintext: secret,
                    kind: MessageSemantics.kindChat,
                    tags: [],
                    recordedAt: 42
                )
            )
        )

        let text = DiagnosticsView.diagnosticText(for: event)

        #expect(text.contains("[alice] msg from \(IdentityFormatter.short(sender))"))
        #expect(text.contains("(\(secret.count) chars)"))
        #expect(!text.contains(secret))

        let emptyEvent = MarmotEventFfi.messageReceived(
            received: RuntimeMessageReceivedFfi(
                accountIdHex: hex("aa"),
                accountLabel: "alice",
                message: ReceivedMessageFfi(
                    messageIdHex: hex("dd"),
                    groupIdHex: hex("cc"),
                    sender: sender,
                    senderDisplayName: nil,
                    plaintext: "",
                    kind: MessageSemantics.kindChat,
                    tags: [],
                    recordedAt: 43
                )
            )
        )

        let emptyText = DiagnosticsView.diagnosticText(for: emptyEvent)
        #expect(emptyText.contains("[alice] msg from \(IdentityFormatter.short(sender))"))
        #expect(emptyText.contains("(empty)"))
        #expect(!emptyText.contains(secret))
    }

    @Test func diagnosticTextLabelsWelcomeDeliveryPending() {
        let groupId = hex("cc")
        let messageId = hex("dd")
        let recipient = hex("ee")
        let event = MarmotEventFfi.welcomeDeliveryPending(
            accountIdHex: hex("aa"),
            accountLabel: "alice",
            groupIdHex: groupId,
            messageIdHex: messageId,
            recipientHex: recipient
        )

        let text = DiagnosticsView.diagnosticText(for: event)

        #expect(text.contains("[alice] welcome pending"))
        #expect(text.contains(IdentityFormatter.short(groupId)))
        #expect(text.contains(IdentityFormatter.short(messageId)))
        #expect(text.contains(IdentityFormatter.short(recipient)))
    }

    @Test func diagnosticTextLabelsEpochStallEscalation() {
        let groupId = hex("cc")
        let event = MarmotEventFfi.epochStallEscalated(
            accountIdHex: hex("aa"),
            accountLabel: "alice",
            groupIdHex: groupId,
            stalledEpoch: 12,
            arms: 3
        )

        let text = DiagnosticsView.diagnosticText(for: event)

        #expect(text.contains("[alice]"))
        #expect(text.contains(IdentityFormatter.short(groupId)))
        #expect(text.contains("epoch 12"))
        #expect(text.contains("3 recovery attempts"))
        #expect(text.contains("re-sync recommended"))
    }

    @Test func diagnosticTextLabelsGroupStateInvalidated() {
        let groupId = hex("cc")
        let event = MarmotEventFfi.groupEvent(
            accountIdHex: hex("aa"),
            accountLabel: "alice",
            groupIdHex: groupId,
            event: .groupStateInvalidated(
                epoch: 2,
                invalidatedCommitIdHex: hex("dd"),
                reason: "superseded_by_branch_selection"
            )
        )

        let text = DiagnosticsView.diagnosticText(for: event)

        #expect(text.contains("[alice] group event state invalidated"))
        #expect(text.contains(IdentityFormatter.short(groupId)))
    }

    @Test func diagnosticTextLabelsTransportObjectResourceRefusal() {
        let groupId = hex("cc")
        let messageId = hex("dd")
        let event = MarmotEventFfi.groupEvent(
            accountIdHex: hex("aa"),
            accountLabel: "alice",
            groupIdHex: groupId,
            event: .transportObjectResourceRefused(
                messageIdHex: messageId,
                resource: "deferred_peel_rows"
            )
        )

        let text = DiagnosticsView.diagnosticText(for: event)

        #expect(text.contains("[alice] group event resource refused"))
        #expect(text.contains(IdentityFormatter.short(groupId)))
        #expect(!text.contains(messageId))
        #expect(!text.contains("deferred_peel_rows"))
    }

    @Test @MainActor func notificationServiceDiagnosticTextUsesLocalizedOperationalShape() {
        let snapshot = NotificationServiceDiagnosticSnapshot(
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationMilliseconds: 931,
            stage: .collectionCompleted,
            outcome: .failed,
            notificationCount: 0
        )

        let english = DiagnosticsView.notificationServiceDiagnosticText(
            snapshot,
            locale: Locale(identifier: "en_US")
        )
        let german = DiagnosticsView.notificationServiceDiagnosticText(
            snapshot,
            locale: Locale(identifier: "de_DE")
        )

        #expect(english.contains("931 ms"))
        #expect(english.contains("0 notifications"))
        #expect(german.contains("0 Benachrichtigungen"))
        #expect(english != german)
        #expect(!english.contains("2023-11-14T22:13:20Z"))
    }

    @Test @MainActor func notificationServiceDiagnosticIsTimestampedAndAppendedOnce() {
        let recordedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = NotificationServiceDiagnosticSnapshot(
            recordedAt: recordedAt,
            durationMilliseconds: 931,
            stage: .collectionCompleted,
            outcome: .failed,
            notificationCount: 0
        )
        let model = DiagnosticsViewModel()

        model.appendNotificationServiceDiagnosticIfNeeded(snapshot)
        model.appendNotificationServiceDiagnosticIfNeeded(snapshot)

        #expect(model.entries.count == 1)
        #expect(model.entries.first?.timestamp == recordedAt)
    }
}
