import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

struct MarmotKitMasterIntegrationTests {
    @MainActor
    @Test func durablyAcceptedComposerOutcomesKeepClockWithoutFailureUI() async throws {
        do {
            let appState = AppState.test(client: try MarmotClient.testClient())
            appState.activeAccountRef = "account-ref"
            let timelineStore = TimelineStore(appState: appState, groupIdHex: hex("aa"))
            let composer = ComposerModel(
                appState: appState,
                groupIdHex: hex("aa"),
                timelineStore: timelineStore
            )
            composer.canSendMessages = { true }
            var surfacedErrors: [String] = []
            composer.onError = { surfacedErrors.append($0) }
            composer.sendTextForTesting = { _, _, _, _, token in
                LocalSendAcceptanceFfi(clientToken: token, messageIdHex: "local")
            }

            await composer.send("durably retained")

            let statuses = timelineStore.timeline.compactMap { item -> MessageStatus? in
                guard case .message(_, let status) = item.kind else { return nil }
                return status
            }
            #expect(statuses == [.sending])
            #expect(surfacedErrors.isEmpty)
            #expect(appState.activeToast == nil)
        }
    }

    @MainActor
    @Test func thrownTransientComposerSendRendersFailedAndSurfacesFailure() async throws {
        let appState = AppState.test(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account-ref"
        let timelineStore = TimelineStore(appState: appState, groupIdHex: hex("aa"))
        let composer = ComposerModel(
            appState: appState,
            groupIdHex: hex("aa"),
            timelineStore: timelineStore
        )
        composer.canSendMessages = { true }
        var surfacedErrors: [String] = []
        composer.onError = { surfacedErrors.append($0) }
        composer.localSendStatusForTesting = { _ in nil }
        composer.sendTextForTesting = { _, _, _, _, _ in
            throw NSError(domain: "ComposerSendTests", code: 1)
        }

        await composer.send("not retained")

        let statuses = timelineStore.timeline.compactMap { item -> MessageStatus? in
            guard case .message(_, let status) = item.kind else { return nil }
            return status
        }
        #expect(statuses == [.failed])
        #expect(surfacedErrors.count == 1)
        #expect(appState.activeToast != nil)
    }

    @Test func accountWorkerErrorsExposeRetrySafetySemantics() {
        #expect(MarmotKitError.AccountWorkerBusy.isAccountWorkerBusy)
        #expect(!MarmotKitError.AccountWorkerBusy.isAccountWorkerResponseTimedOut)
        #expect(MarmotKitError.AccountWorkerResponseTimedOut.isAccountWorkerResponseTimedOut)
        #expect(!MarmotKitError.AccountWorkerResponseTimedOut.isAccountWorkerBusy)
    }

    @Test func convergenceRetryPolicyRefreshesAmbiguousResultsAndStopsUnrecoverableGroups() {
        #expect(DurableConvergenceRetryPolicy.action(
            for: MarmotKitError.AccountWorkerBusy
        ) == .retry)
        #expect(DurableConvergenceRetryPolicy.action(
            for: MarmotKitError.AccountWorkerResponseTimedOut
        ) == .refreshBeforeRetry)
        #expect(DurableConvergenceRetryPolicy.action(
            for: MarmotKitError.GroupUnrecoverableRepairRequired(groupIdHex: "group")
        ) == .stop)
    }

    @Test @MainActor func hostPerformanceSnapshotRoundTripsThroughBindings() throws {
        let client = try MarmotClient.testClient()
        let before = client.appPerformanceSnapshot().hostSplashReady

        client.recordHostPerformance(
            operation: .splashReady,
            durationMs: 250,
            outcome: .success
        )
        let after = client.appPerformanceSnapshot().hostSplashReady

        #expect(after.attempts >= before.attempts + 1)
        #expect(after.successes >= before.successes + 1)
        #expect(after.durationMs.sumMs >= before.durationMs.sumMs + 250)
    }
}
