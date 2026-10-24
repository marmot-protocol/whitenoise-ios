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
struct ReceivedMessageTimestampTests {

    /// Regression for the timeline-sort bug: live messages must keep the
    /// event's own send time as `recordedAt`, not the device clock at receipt.
    /// Otherwise a late-arriving message (e.g. after a reconnect) would sort
    /// after messages sent moments ago.
    @Test func liveMessageUsesEventTimestampForRecordedAt() {
        let eventTime: UInt64 = 1_700_000_000
        let now: UInt64 = 1_700_000_500
        let runtime = RuntimeMessageReceivedFfi(
            accountIdHex: hex("11"),
            accountLabel: "account-a",
            message: receivedMessage(recordedAt: eventTime)
        )

        let record = ConversationViewModel.receivedToRecord(runtime, now: now)

        #expect(record.recordedAt == eventTime)
        #expect(record.receivedAt == now)
    }

    /// If the FFI omits a timestamp (zero sentinel — possible for very old
    /// stored events or a future relay that drops it), fall back to the local
    /// receipt time so the message still has a sensible ordering anchor.
    @Test func liveMessageFallsBackToNowWhenEventTimestampMissing() {
        let now: UInt64 = 1_700_000_500
        let runtime = RuntimeMessageReceivedFfi(
            accountIdHex: hex("11"),
            accountLabel: "account-a",
            message: receivedMessage(recordedAt: 0)
        )

        let record = ConversationViewModel.receivedToRecord(runtime, now: now)

        #expect(record.recordedAt == now)
        #expect(record.receivedAt == now)
    }

    @Test func receivedRecordCopiesIdentityAndPayloadFields() {
        let runtime = RuntimeMessageReceivedFfi(
            accountIdHex: hex("11"),
            accountLabel: "account-a",
            message: receivedMessage(recordedAt: 42)
        )

        let record = ConversationViewModel.receivedToRecord(runtime, now: 99)

        #expect(record.direction == "received")
        #expect(record.messageIdHex == runtime.message.messageIdHex)
        #expect(record.groupIdHex == runtime.message.groupIdHex)
        #expect(record.sender == runtime.message.sender)
        #expect(record.plaintext == runtime.message.plaintext)
        #expect(record.kind == runtime.message.kind)
        #expect(record.tags == runtime.message.tags)
    }

    @Test func receivedRecordPreservesSourceRetentionAndObservationMetadata() {
        let message = ReceivedMessageFfi(
            messageIdHex: hex("cc"),
            groupIdHex: hex("aa"),
            sender: hex("11"),
            senderDisplayName: nil,
            plaintext: "hello",
            contentTokens: .emptyDocument,
            kind: MessageSemantics.kindChat,
            tags: [],
            sourceEpoch: 12,
            retentionSeconds: 60,
            retentionExpiresAt: 1_700_000_060,
            recordedAt: 1_700_000_000,
            receivedAt: 1_700_000_010
        )
        let runtime = RuntimeMessageReceivedFfi(
            accountIdHex: hex("11"),
            accountLabel: "account-a",
            message: message
        )

        let record = ConversationViewModel.receivedToRecord(runtime, now: 1_800_000_000)

        #expect(record.sourceEpoch == message.sourceEpoch)
        #expect(record.retentionSeconds == message.retentionSeconds)
        #expect(record.retentionExpiresAt == message.retentionExpiresAt)
        #expect(record.receivedAt == message.receivedAt)
    }

    private func receivedMessage(recordedAt: UInt64) -> ReceivedMessageFfi {
        ReceivedMessageFfi(
            messageIdHex: hex("cc"),
            groupIdHex: hex("aa"),
            sender: hex("11"),
            senderDisplayName: nil,
            plaintext: "hello",
            kind: MessageSemantics.kindChat,
            tags: [MessageTagFfi(values: ["e", hex("dd")])],
            recordedAt: recordedAt
        )
    }
}
