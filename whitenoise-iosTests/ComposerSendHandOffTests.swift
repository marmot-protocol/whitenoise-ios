import Foundation
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

@MainActor
private final class SendOrderRecorder {
    var entries: [String] = []
}

@MainActor
struct ComposerSendHandOffTests {
    @Test func uploadFailureBeforeDraftSubmissionRemainsRetryable() {
        let failure = MarmotKitError.Runtime(details: "upload failed")
        #expect(!SendFailurePolicy.awaitsDurableState(error: failure, submittedDraft: false))
        #expect(SendFailurePolicy.awaitsDurableState(error: failure, submittedDraft: true))
        #expect(SendFailurePolicy.awaitsDurableState(error: CancellationError(), submittedDraft: false))
        #expect(SendFailurePolicy.awaitsDurableState(error: MarmotKitError.AccountWorkerResponseTimedOut, submittedDraft: false))
    }

    @Test func admittedTimeoutKeepsAnUnresolvedBubbleWithoutFreshSendRetry() async throws {
        let client = try MarmotClient.testClient()
        let state = AppState(client: client)
        state.activeAccountRef = "account-ref"
        let store = TimelineStore(appState: state, groupIdHex: hex("aa"))
        let composer = ComposerModel(appState: state, groupIdHex: hex("aa"), timelineStore: store)
        composer.canSendMessages = { true }
        composer.sendTextForTesting = { _, _, _, _ in throw MarmotKitError.AccountWorkerResponseTimedOut }
        await composer.send("uncertain send")
        let row = try #require(store.timeline.first)
        #expect(store.localSendPhase(rowID: row.id) == .completionUnknown)
        #expect(store.failedTransientRecord(rowId: row.id) == nil)
        #expect(state.activeToast == nil)
        try await client.marmot.shutdownAndClose()
    }

    @Test func lateSendResultAfterTeardownCannotRecreateItsBubble() async throws {
        let client = try MarmotClient.testClient()
        let state = AppState(client: client)
        state.activeAccountRef = "account-ref"
        let store = TimelineStore(appState: state, groupIdHex: hex("aa"))
        let composer = ComposerModel(appState: state, groupIdHex: hex("aa"), timelineStore: store)
        composer.canSendMessages = { true }
        composer.sendTextForTesting = { _, _, _, _ in
            store.resetOptimisticState()
            return SendSummaryFfi(published: 1, messageIds: ["late"], acceptDisposition: .published, maintenanceDisposition: .ready)
        }
        await composer.send("retired send")
        #expect(store.timeline.isEmpty)
        try await client.marmot.shutdownAndClose()
    }

    @Test func queuedSendFailureUsesReadableInlineAndToastMessages() async throws {
        let client = try MarmotClient.testClient()
        let appState = AppState(client: client)
        appState.activeAccountRef = "account-ref"
        let timelineStore = TimelineStore(appState: appState, groupIdHex: hex("aa"))
        let composer = ComposerModel(appState: appState, groupIdHex: hex("aa"), timelineStore: timelineStore)
        composer.canSendMessages = { true }
        var inlineError: String?
        composer.onError = { inlineError = $0 }
        composer.sendTextForTesting = { _, _, _, _ in
            throw MarmotKitError.Runtime(details: "relay disconnected")
        }

        await composer.send("hello")

        #expect(inlineError == "Relay disconnected")
        #expect(appState.activeToast?.title == "Send failed")
        #expect(appState.activeToast?.message == "Relay disconnected")
        #expect(!composer.sendInFlight)
        try await client.marmot.shutdownAndClose()
    }

    @Test func queuedSendsPublishInTheOrderTheyWereEnqueued() async {
        let queue = OutgoingSendQueue()
        let recorder = SendOrderRecorder()

        let first = queue.enqueue {
            recorder.entries.append("first-begin")
            for _ in 0..<8 { await Task.yield() }
            recorder.entries.append("first-end")
        }
        let second = queue.enqueue {
            recorder.entries.append("second-begin")
            recorder.entries.append("second-end")
        }

        await first.value
        await second.value

        #expect(recorder.entries == ["first-begin", "first-end", "second-begin", "second-end"])
    }

    @Test func aFailingSendStillReleasesTheSendQueuedBehindIt() async {
        let queue = OutgoingSendQueue()
        let recorder = SendOrderRecorder()

        let first = queue.enqueue {
            await Task.yield()
            recorder.entries.append("failed")
        }
        let second = queue.enqueue {
            recorder.entries.append("delivered")
        }

        await first.value
        await second.value

        #expect(recorder.entries == ["failed", "delivered"])
    }

    @Test func composerIsFreeToSendAgainWhileTheRelayRoundTripIsStillRunning() async throws {
        let appState = AppState(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account-ref"
        let timelineStore = TimelineStore(appState: appState, groupIdHex: hex("aa"))
        let composer = ComposerModel(
            appState: appState,
            groupIdHex: hex("aa"),
            timelineStore: timelineStore
        )
        composer.canSendMessages = { true }
        var sendInFlightDuringPublish: [Bool] = []
        composer.sendTextForTesting = { _, _, _, _ in
            sendInFlightDuringPublish.append(composer.sendInFlight)
            return SendSummaryFfi(
                published: 1,
                messageIds: ["a"],
                acceptDisposition: .published,
                maintenanceDisposition: .ready
            )
        }

        await composer.send("first")

        #expect(sendInFlightDuringPublish == [false])
        #expect(!composer.sendInFlight)
    }
}

private func hex(_ byte: String) -> String {
    String(repeating: byte, count: 32)
}
