#if DEBUG
import Foundation
import MarmotKit

actor ScenarioAccountSetupClient: AccountSetupClient {
    private var snapshot: OnboardingSnapshotFfi
    private let scenario: AccountRecoveryScenario.State
    private weak var session: AccountRecoveryScenarioSession?
    private var subscriptionCount = 0

    init(snapshot: OnboardingSnapshotFfi, scenario: AccountRecoveryScenario.State, session: AccountRecoveryScenarioSession) {
        self.snapshot = snapshot
        self.scenario = scenario
        self.session = session
    }

    func subscribe() async throws -> AccountSetupSubscription {
        subscriptionCount += 1
        if (scenario == .disconnected || scenario == .readyDisconnected), subscriptionCount == 1 { throw URLError(.notConnectedToInternet) }
        let endsImmediately = scenario == .stopped && subscriptionCount == 1
        return AccountSetupSubscription(snapshot: snapshot, next: {
            if endsImmediately { return nil }
            // A held subscription must still drain promptly on reset or dismissal.
            while true { try await Task.sleep(for: .seconds(10)) }
        })
    }

    func perform(_ command: AccountSetupCommand) async throws -> OnboardingSnapshotFfi? {
        if case .run = command {
            if scenario == .checkingSecureMessaging {
                try await session?.waitWhileHeld()
                finishAll()
            } else if scenario == .checking || scenario == .pending {
                try await session?.waitWhileHeld()
                advanceToDeviceCheck()
            }
            return snapshot
        }
        try await Task.sleep(for: .milliseconds(450))
        snapshot.revision += 1
        switch command {
        case .cancel: return nil
        case .discovery:
            snapshot.steps = snapshot.steps.map { step in
                var next = step
                if step.step == .relays || step.step == .inboxRelays, step.status != .passed {
                    next.status = .needsInput
                    next.actions = [.useRecommendedRelays, .editDiscoveryRelays]
                    next.findings = [.init(issue: .missing, endpoint: nil)]
                }
                return next
            }
        case .run: break
        case .acknowledge(let revision, let epoch):
            guard revision == snapshot.revision - 1, epoch == snapshot.recoveryEpoch else {
                throw MarmotKitError.OnboardingActionUnavailable
            }
            finishAll()
        case .skip(let step):
            advanceToDeviceCheck()
            if let index = snapshot.steps.firstIndex(where: { $0.step == step }) { snapshot.steps[index].status = .skipped }
        default:
            if snapshot.steps.first(where: { $0.step == .singleDevice })?.status == .passed { finishAll() }
            else { advanceToDeviceCheck() }
        }
        return snapshot
    }

    private func finishAll() {
        snapshot.revision += 1
        snapshot.ready = true
        snapshot.proposal = nil
        snapshot.steps = snapshot.steps.map {
            var step = $0
            step.status = step.step == .follows || step.status == .skipped ? .skipped : .passed
            step.findings = []
            step.actions = []
            return step
        }
    }

    private func advanceToDeviceCheck() {
        finishAll()
        snapshot.ready = false
        if let index = snapshot.steps.firstIndex(where: { $0.step == .singleDevice }) {
            snapshot.steps[index].status = .needsInput
            snapshot.steps[index].actions = [.continueAnyway]
        }
        if let index = snapshot.steps.firstIndex(where: { $0.step == .keyPackage }) { snapshot.steps[index].status = .pending }
        snapshot.singleDeviceNotice = .init(discovery: .noneFound, otherPackages: [], discoveryComplete: true, acknowledgedAt: nil)
    }

    @MainActor static func snapshot(for scenario: AccountRecoveryScenario.State) -> OnboardingSnapshotFfi {
        var step: OnboardingStepFfi = .relays
        var status: OnboardingStatusFfi = .needsInput
        var actions: [OnboardingActionFfi] = [.useRecommendedRelays, .editDiscoveryRelays]
        var issues: [OnboardingIssueFfi] = [.missing]
        var discovery: OnboardingDeviceDiscoveryFfi?
        switch scenario {
        case .checking: step = .profile; status = .checking; actions = []; issues = []
        case .pending: step = .profile; status = .pending; actions = []; issues = []
        case .checkingSecureMessaging: step = .keyPackage; status = .checking; actions = []; issues = []
        case .profile: step = .profile; actions = [.editProfile, .continueWithout]
        case .profileFailed: step = .profile; status = .retryableFailure; actions = [.retry, .continueWithout]; issues = [.timedOut]
        case .profileSkipped:
            step = .singleDevice; actions = [.continueAnyway]; issues = []
            discovery = .noneFound
        default: break
        }
        let ready = [.ready, .openingFailed, .readyDisconnected, .opening].contains(scenario)
        let order: [OnboardingStepFfi] = [.profile, .follows, .relays, .inboxRelays, .singleDevice, .keyPackage]
        let currentIndex = order.firstIndex(of: step)!
        let steps = order.enumerated().map { index, kind in
            OnboardingStepStateFfi(step: kind,
                status: ready || index < currentIndex ? (kind == .follows || (kind == .profile && (scenario == .profileSkipped || scenario == .checkingSecureMessaging)) ? .skipped : .passed) : kind == step ? status : .pending,
                findings: !ready && kind == step ? issues.map { .init(issue: $0, endpoint: kind == .relays ? "wss://relay.example.com" : nil) } : [],
                actions: !ready && kind == step ? actions : [], checkedAt: nil)
        }
        return OnboardingSnapshotFfi(accountIdHex: AccountRecoveryScenarioSession.account.accountIdHex,
            recoveryEpoch: "scenario-epoch", revision: 1, ready: ready, steps: steps, proposal: nil,
            singleDeviceNotice: discovery.map {
                .init(discovery: $0, otherPackages: [], discoveryComplete: $0 != .unknown, acknowledgedAt: nil)
            }, cancellationPending: false)
    }
}
#endif
