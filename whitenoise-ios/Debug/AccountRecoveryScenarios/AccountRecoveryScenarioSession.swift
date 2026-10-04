#if DEBUG
import MarmotKit
import SwiftUI

@MainActor @Observable
final class AccountRecoveryScenarioSession: AccountSetupSession {
    static let account = AccountSummaryFfi(
        label: "Scenario Profile", accountIdHex: String(repeating: "a", count: 64),
        localSigning: true, externalSigning: false, signedOut: false, running: false
    )
    let model: AccountSetupModel
    let scenario: AccountRecoveryScenario
    var isHolding: Bool
    private(set) var completed = false
    private(set) var isFinishingAccountSetup = false
    private(set) var canUseRuntimeForLocalForegroundWork = true
    let runtimeGeneration = 1
    private var stopped = false
    private var failedOperations: Set<String> = []
    @ObservationIgnored private var client: ScenarioAccountSetupClient?

    init(scenario: AccountRecoveryScenario) {
        self.scenario = scenario
        let snapshot = ScenarioAccountSetupClient.snapshot(for: scenario.state)
        model = AccountSetupModel(snapshot: snapshot)
        isHolding = [.checking, .checkingSecureMessaging, .pending, .opening].contains(scenario.state)
        client = ScenarioAccountSetupClient(snapshot: snapshot, scenario: scenario.state, session: self)
    }

    func connectAccountSetup() async {
        guard !stopped, let client else { return }
        await model.connect(client)
    }

    func cancelAccountSetup() async -> Bool {
        guard !stopped else { return false }
        if scenario.state == .cancellationFailed, failedOperations.insert("cancel").inserted {
            model.suspend()
            model.errorMessage = L10n.string("Couldn’t close sign-in. Try again when the current update has finished.")
            return false
        }
        stop()
        await model.drain()
        return true
    }

    func finishAccountSetup() async {
        guard !stopped, model.canFinish, !isFinishingAccountSetup else { return }
        isFinishingAccountSetup = true
        defer { isFinishingAccountSetup = false }
        do {
            if scenario.state == .opening { try await waitWhileHeld() }
            try await Task.sleep(for: .milliseconds(350))
            guard !stopped else { return }
            if scenario.state == .openingFailed, failedOperations.insert("finish").inserted {
                throw URLError(.notConnectedToInternet)
            }
            completed = true
            model.suspend()
        } catch {
            guard !Task.isCancelled, !stopped else { return }
            model.errorMessage = L10n.string("Couldn’t refresh your accounts. Try again.")
        }
    }

    func waitWhileHeld() async throws {
        while isHolding && !stopped { try await Task.sleep(for: .milliseconds(100)) }
        try Task.checkCancellation()
        if stopped { throw CancellationError() }
    }

    func stop() {
        stopped = true
        canUseRuntimeForLocalForegroundWork = false
        model.suspend()
    }
}
#endif
