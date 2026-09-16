import Foundation
import Testing
import MarmotKit
@testable import whitenoise_ios

@MainActor
@Suite(.serialized)
struct AccountAttentionCreationTests {
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["WN_RUN_ATTENTION_CREATION_DIAGNOSTIC"] == "1"),
        arguments: [false, true]
    )
    func generatedAccountReadinessWithAndWithoutAttention(useAttention: Bool) async throws {
        let client = try MarmotClient.testClient()
        let appState = AppState(client: client)
        appState.accountAttentionEnabledForTesting = useAttention
        await appState.bootstrap()
        var stage = "first identity"
        do {
            let first = try await appState.createIdentity()
            stage = "readiness after first identity"
            var ready = false
            for _ in 0..<300 {
                if try client.marmot.accountSetupReadiness(accountRef: first.label) == .networkReady {
                    ready = true
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            try #require(ready, "The first identity must reach relay readiness before testing second-account creation")
            stage = "second identity"
            let second = try await appState.createIdentity()
            #expect(second.accountIdHex != first.accountIdHex)
        } catch {
            Issue.record("Attention enabled: \(useAttention); stage: \(stage); error: \(error)")
        }
        await appState.startRuntimeSuspension().value
    }
}
