import Testing
@testable import whitenoise_ios
@testable import MarmotKit

@MainActor
private final class SendOrderRecorder {
    var entries: [String] = []
}

@MainActor
struct ComposerSendHandOffTests {
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
