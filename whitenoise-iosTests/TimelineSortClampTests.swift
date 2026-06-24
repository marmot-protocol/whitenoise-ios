import Testing
@testable import whitenoise_ios
@testable import MarmotKit

/// #61 — the timeline sort key must be clamped to min(recordedAt, receivedAt) so
/// a future-dated message can't pin itself to the bottom of the conversation.
/// Display still uses the record's own recordedAt.
struct TimelineSortClampTests {
    private func record(
        messageIdHex: String = String(repeating: "a", count: 64),
        recordedAt: UInt64,
        receivedAt: UInt64
    ) -> AppMessageRecordFfi {
        AppMessageRecordFfi(
            messageIdHex: messageIdHex,
            direction: "received",
            groupIdHex: String(repeating: "c", count: 64),
            sender: String(repeating: "b", count: 64),
            plaintext: "hi",
            kind: MessageSemantics.kindChat,
            tags: [],
            recordedAt: recordedAt,
            receivedAt: receivedAt
        )
    }

    @Test func clampsFutureRecordedToReceived() {
        #expect(TimelineItem.sortTimestamp(for: record(recordedAt: 9_000_000, receivedAt: 1_000)) == 1_000)
    }

    @Test func usesRecordedWhenInThePast() {
        #expect(TimelineItem.sortTimestamp(for: record(recordedAt: 500, receivedAt: 1_000)) == 500)
    }

    @Test func fallsBackToRecordedWhenReceivedMissing() {
        #expect(TimelineItem.sortTimestamp(for: record(recordedAt: 500, receivedAt: 0)) == 500)
    }

    @Test func messageFactoryUsesClampedTimestamp() {
        #expect(TimelineItem.message(record(recordedAt: 9_000_000, receivedAt: 1_000)).timestamp == 1_000)
    }

    @Test func rowFrameKeyUsesStableRowIdentityForConfirmedMessages() {
        let message = TimelineItem.message(record(recordedAt: 500, receivedAt: 1_000))

        #expect(message.rowFrameKey == message.id)
        #expect(message.rowFrameKey == "msg:\(String(repeating: "a", count: 64))")
    }

    /// #411 — `TimelineItem.message` is invoked per record during the idempotent
    /// timeline rebuild, so the same record must map to the same row id on every
    /// call. A freshly-minted UUID fallback broke that (each rebuild churned the
    /// row and leaked the projection caches keyed by the prior id).
    @Test func messageFactoryProducesStableIdAcrossRebuilds() {
        let stable = record(recordedAt: 500, receivedAt: 1_000)

        let first = TimelineItem.message(stable)
        let second = TimelineItem.message(stable)

        #expect(first.id == second.id)
        #expect(first.id == "msg:\(String(repeating: "a", count: 64))")
    }

    /// #411 — the empty-`messageIdHex` path is the actual bug class: the old
    /// implementation minted a fresh `UUID().uuidString` for an empty id, so two
    /// derivations of the *same* empty-id record produced *different* row ids,
    /// churning the rebuild and leaking the projection caches. The factory now
    /// asserts against empty ids in debug, so this exercises the pure derivation
    /// helper directly: it must be deterministic (same id every call) and degrade
    /// to the stable `"msg:"` prefix rather than a per-call UUID.
    @Test func messageRowIdIsStableForEmptyMessageIdHex() {
        let first = TimelineItem.messageRowId(forMessageIdHex: "")
        let second = TimelineItem.messageRowId(forMessageIdHex: "")

        #expect(first == second)
        #expect(first == "msg:")
    }

    @Test func rowFrameKeyDoesNotCollapseEmptyMessageIdRows() {
        let emptyRecord = record(messageIdHex: "", recordedAt: 500, receivedAt: 1_000)
        let first = TimelineItem.pendingMessage(tempId: "pending-1", record: emptyRecord)
        let second = TimelineItem.pendingMessage(tempId: "pending-2", record: emptyRecord)

        #expect(first.rowFrameKey == "msg:pending-1")
        #expect(second.rowFrameKey == "msg:pending-2")
        #expect(first.rowFrameKey != second.rowFrameKey)
        #expect(!first.rowFrameKey.isEmpty)
        #expect(!second.rowFrameKey.isEmpty)
    }
}
