import Foundation
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

@MainActor
struct ComposerSendHandOffTests {
    private let appState: AppState
    private let timelineStore: TimelineStore
    private let composer: ComposerModel

    init() throws {
        appState = AppState(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account-ref"
        timelineStore = TimelineStore(appState: appState, groupIdHex: hex("aa"))
        composer = ComposerModel(
            appState: appState,
            groupIdHex: hex("aa"),
            timelineStore: timelineStore
        )
        composer.canSendMessages = { true }
    }

    @Test func queuedSendsPublishInTheOrderTheyWereEnqueued() async {
        let queue = OutgoingSendQueue()
        var entries: [String] = []

        let first = queue.enqueue {
            entries.append("first-begin")
            for _ in 0..<8 { await Task.yield() }
            entries.append("first-end")
        }
        let second = queue.enqueue {
            entries.append("second-begin")
            entries.append("second-end")
        }

        await first.value
        await second.value

        #expect(entries == ["first-begin", "first-end", "second-begin", "second-end"])
    }

    /// The draft is cleared the instant Send is pressed, so a send the composer
    /// declines to start is content the user can never get back.
    @Test func simultaneousSendsBothReachTheRelays() async {
        var published: [String] = []
        composer.sendTextForTesting = { _, _, _, text in
            published.append(text)
            return publishedSummary(messageId: text)
        }

        async let first: Void = composer.send("first")
        async let second: Void = composer.send("second")
        _ = await (first, second)

        #expect(published.sorted() == ["first", "second"])
    }

    @Test func aSendPressedDuringAnothersRoundTripParksItsRowAndPublishesBehindIt() async {
        var publishing: [String] = []
        var firstRoundTripMayFinish = false
        composer.sendTextForTesting = { _, _, _, text in
            publishing.append(text)
            if text == "first" {
                await yieldUntil { firstRoundTripMayFinish }
            }
            return publishedSummary(messageId: text)
        }

        let composer = self.composer
        let timelineStore = self.timelineStore
        let first = Task { await composer.send("first") }
        await yieldUntil { !publishing.isEmpty }
        let second = Task { await composer.send("second") }
        await yieldUntil { timelineStore.timeline.count == 2 }
        let rowsParkedMidRoundTrip = timelineStore.timeline.count
        firstRoundTripMayFinish = true
        await first.value
        await second.value

        #expect(rowsParkedMidRoundTrip == 2)
        #expect(publishing == ["first", "second"])
    }

    @Test func aThrownSendFailsOnlyItsOwnRowAndReleasesTheSendBehindIt() async {
        var surfacedErrors: [String] = []
        composer.onError = { surfacedErrors.append($0) }
        var publishedTexts: [String] = []
        composer.sendTextForTesting = { _, _, _, text in
            guard text != "first" else {
                // Stay in flight long enough for the second send to queue up
                // behind this one before it fails.
                for _ in 0..<40 { await Task.yield() }
                throw NSError(domain: "ComposerSendHandOffTests", code: 1)
            }
            publishedTexts.append(text)
            return publishedSummary(messageId: text)
        }

        async let first: Void = composer.send("first")
        async let second: Void = composer.send("second")
        _ = await (first, second)

        let statuses = Set(timelineStore.timeline.compactMap { item -> MessageStatus? in
            guard case .message(_, let status) = item.kind else { return nil }
            return status
        })
        #expect(publishedTexts == ["second"])
        #expect(statuses == [.failed, .sent])
        #expect(surfacedErrors.count == 1)
    }
}

private func publishedSummary(messageId: String) -> SendSummaryFfi {
    SendSummaryFfi(
        published: 1,
        messageIds: [messageId],
        acceptDisposition: .published,
        maintenanceDisposition: .ready
    )
}

/// Waits for main-actor work to settle without a wall-clock sleep, and gives up
/// rather than hanging the suite when the condition never becomes true.
@MainActor
private func yieldUntil(_ condition: () -> Bool) async {
    for _ in 0..<500 {
        if condition() { return }
        await Task.yield()
    }
}

private func hex(_ byte: String) -> String {
    String(repeating: byte, count: 32)
}
