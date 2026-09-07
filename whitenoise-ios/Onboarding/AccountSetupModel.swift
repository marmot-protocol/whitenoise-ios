import Foundation
import MarmotKit

nonisolated enum AccountSetupCommand: Sendable {
    case run, cancel, retry(OnboardingStepFfi), skip(OnboardingStepFfi)
    case acknowledge(UInt64), approve(UInt64), cancelRepair
    case useDefaults(OnboardingStepFfi)
    case discovery([String]), saveProfile(UserProfileMetadataFfi, AccountSetupAvatar?)
}

nonisolated struct AccountSetupSubscription: Sendable {
    let snapshot: OnboardingSnapshotFfi
    let next: @Sendable () async throws -> OnboardingSnapshotFfi?
}

// UniFFI 0.29 cannot cancel the Rust subscription's indefinite next() wait.
// Poll finite local reads until the bindings expose a cancellable subscription.
actor AccountSetupSnapshotPoller {
    private var revision: UInt64
    private var ready: Bool
    private let read: @Sendable () async throws -> OnboardingSnapshotFfi?

    init(snapshot: OnboardingSnapshotFfi, read: @escaping @Sendable () async throws -> OnboardingSnapshotFfi?) {
        revision = snapshot.revision
        ready = snapshot.ready && !snapshot.cancellationPending
        self.read = read
    }

    func next() async throws -> OnboardingSnapshotFfi? {
        while !ready {
            try await Task.sleep(for: .milliseconds(250))
            guard let snapshot = try await read() else { return nil }
            try Task.checkCancellation()
            guard snapshot.revision > revision else { continue }
            revision = snapshot.revision
            ready = snapshot.ready && !snapshot.cancellationPending
            return snapshot
        }
        return nil
    }
}

nonisolated protocol AccountSetupClient: Sendable {
    func subscribe() async throws -> AccountSetupSubscription
    func perform(_ command: AccountSetupCommand) async throws -> OnboardingSnapshotFfi?
}

nonisolated struct MarmotAccountSetupClient: AccountSetupClient {
    let client: MarmotClient
    let accountID: String

    func subscribe() async throws -> AccountSetupSubscription {
        guard let snapshot = try await client.onboardingSnapshot(accountID: accountID) else {
            throw MarmotKitError.OnboardingActionUnavailable
        }
        let poller = AccountSetupSnapshotPoller(snapshot: snapshot) { [client, accountID] in
            try await client.onboardingSnapshot(accountID: accountID)
        }
        return AccountSetupSubscription(snapshot: snapshot, next: { try await poller.next() })
    }

    func perform(_ command: AccountSetupCommand) async throws -> OnboardingSnapshotFfi? {
        let marmot = client.marmot
        switch command {
        case .run: return try await marmot.runOnboarding(accountRef: accountID)
        case .cancel:
            try await marmot.cancelOnboarding(accountRef: accountID)
            return nil
        case .retry(let step): return try await marmot.retryOnboardingStep(accountRef: accountID, step: step)
        case .skip(let step): return try await marmot.continueOnboardingWithout(accountRef: accountID, step: step)
        case .acknowledge(let revision):
            return try await marmot.acknowledgeOnboardingSingleDevice(accountRef: accountID, revision: revision)
        case .approve(let revision):
            return try await marmot.approveOnboardingRepair(accountRef: accountID, revision: revision)
        case .cancelRepair: return try await marmot.cancelOnboardingRepair(accountRef: accountID)
        case .useDefaults(let step):
            return try await AccountSetupPublication.publish(step: step, propose: {
                try await marmot.proposeOnboardingRelays(
                    accountRef: accountID, step: step, readRelays: MarmotClient.seedRelays,
                    writeRelays: step == .relays ? MarmotClient.seedRelays : []
                )
            }, approve: { revision in
                try await marmot.approveOnboardingRepair(accountRef: accountID, revision: revision)
            })
        case .discovery(let relays):
            return try await marmot.setOnboardingDiscoveryRelays(accountRef: accountID, discoveryRelays: relays)
        case .saveProfile(var profile, let avatar):
            if let avatar {
                let uploaded = try await client.uploadProfileImage(
                    accountRef: accountID, data: avatar.data, mediaType: avatar.mediaType, blossomServer: nil
                )
                guard let url = ContentSanitizer.imageURL(uploaded) else {
                    throw ProfileImageUploadError.invalidReturnedURL
                }
                profile.picture = url.absoluteString
            }
            try Task.checkCancellation()
            let draft = profile
            return try await AccountSetupPublication.publish(step: .profile, propose: {
                try await marmot.proposeOnboardingProfile(accountRef: accountID, profile: draft)
            }, approve: { revision in
                try await marmot.approveOnboardingRepair(accountRef: accountID, revision: revision)
            })
        }
    }
}

@MainActor @Observable
final class AccountSetupModel {
    private(set) var snapshot: OnboardingSnapshotFfi
    private(set) var isBusy = false
    private(set) var isConnected = false
    private(set) var cancelled = false
    var errorMessage: String?
    @ObservationIgnored private var client: (any AccountSetupClient)?
    @ObservationIgnored private var observer: Task<Void, Never>?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var session = UUID()
    @ObservationIgnored private var lastAutomaticRevision: UInt64?

    init(snapshot: OnboardingSnapshotFfi) { self.snapshot = snapshot }

    var accountID: String { snapshot.accountIdHex }
    var canFinish: Bool {
        !isBusy && (cancelled || (snapshot.ready && !snapshot.cancellationPending && isConnected && errorMessage == nil))
    }
    var offeredActions: Set<OnboardingActionFfi> { Set(snapshot.steps.flatMap(\.actions)) }
    var currentStep: OnboardingStepStateFfi? {
        snapshot.steps.first { $0.status != .passed && $0.status != .skipped }
    }
    var isResumingProfilePublication: Bool {
        guard snapshot.proposal?.step == .profile,
              let actions = snapshot.steps.first(where: { $0.step == .profile })?.actions else { return false }
        return !actions.contains(.approveRepair) && !actions.contains(.cancelRepair)
    }

    func apply(_ next: OnboardingSnapshotFfi) {
        guard next.accountIdHex == accountID, next.revision >= snapshot.revision else { return }
        snapshot = next
    }

    func connect(_ client: any AccountSetupClient) async {
        suspend()
        let id = session
        await drain()
        guard session == id, !Task.isCancelled else { return }
        self.client = client
        lastAutomaticRevision = nil
        observer = Task { [weak self] in
            do {
                let subscription = try await client.subscribe()
                guard let self, self.session == id, !Task.isCancelled else { return }
                self.apply(subscription.snapshot)
                self.isConnected = true
                self.errorMessage = nil
                self.send(self.snapshot.cancellationPending ? .cancel : .run)
                while let update = try await subscription.next() {
                    guard self.session == id, !Task.isCancelled else { return }
                    self.apply(update)
                    self.advanceOptionalSteps()
                }
                guard self.session == id, !Task.isCancelled, !self.cancelled,
                      !self.snapshot.ready || self.snapshot.cancellationPending else { return }
                self.isConnected = false
                self.errorMessage = L10n.string("Setup updates stopped. Reconnect to continue.")
            } catch {
                guard let self, self.session == id, !Task.isCancelled else { return }
                self.isConnected = false
                self.errorMessage = L10n.string("Couldn’t load account setup. Reconnect to try again.")
            }
        }
    }

    @discardableResult
    func send(_ command: AccountSetupCommand) -> Task<Void, Never>? {
        guard !isBusy, let client, isConnected else { return nil }
        let id = session
        isBusy = true
        errorMessage = nil
        operation = Task { [weak self] in
            do {
                let result = try await client.perform(command)
                guard let self, self.session == id, !Task.isCancelled else { return }
                if let result { self.apply(result) } else { self.cancelled = true }
            } catch {
                guard let self, self.session == id, !Task.isCancelled else { return }
                if let error = error as? MarmotKitError, case .OnboardingActionUnavailable = error {
                    self.errorMessage = L10n.string("Setup changed. Reconnect and review the latest options.")
                } else {
                    self.errorMessage = L10n.string("Setup couldn’t finish this action. Your progress is saved. Try again.")
                }
            }
            guard let self, self.session == id else { return }
            self.isBusy = false
            self.operation = nil
            self.advanceOptionalSteps()
        }
        return operation
    }

    func saveProfile(_ profile: UserProfileMetadataFfi, avatar: AccountSetupAvatar?) async -> Bool {
        let id = session
        guard let task = send(isResumingProfilePublication ? .retry(.profile) : .saveProfile(profile, avatar)) else { return false }
        await task.value
        return session == id && errorMessage == nil && snapshot.steps.first { $0.step == .profile }?.status == .passed
    }

    private func advanceOptionalSteps() {
        guard !isBusy, isConnected, errorMessage == nil,
              let command = AccountSetupPolicy.automaticAction(snapshot) else { return }
        guard lastAutomaticRevision != snapshot.revision else {
            errorMessage = L10n.string("Setup couldn’t finish this action. Your progress is saved. Try again.")
            return
        }
        lastAutomaticRevision = snapshot.revision
        send(command)
    }

    func suspend() {
        session = UUID()
        isConnected = false
        isBusy = false
        client = nil
        observer?.cancel()
        operation?.cancel()
    }

    func drain() async {
        let id = session
        let previousObserver = observer
        let previousOperation = operation
        await previousObserver?.value
        await previousOperation?.value
        guard session == id else { return }
        observer = nil
        operation = nil
    }
}

nonisolated enum AccountSetupInput {
    static func relays(_ text: String) -> [String]? {
        guard text.utf8.count <= 16_384 else { return nil }
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count <= 16, !tokens.isEmpty else { return nil }
        var result: [String] = []
        for token in tokens {
            guard let relay = RelayURL.normalized(token) else { return nil }
            if !result.contains(relay) { result.append(relay) }
        }
        return result
    }

    static func proposalRelays(_ relays: [String]) -> [String]? {
        guard relays.count <= 16 else { return nil }
        var result: [String] = []
        for raw in relays {
            guard !raw.unicodeScalars.contains(where: { $0.properties.generalCategory == .format
                || $0.properties.generalCategory == .control }),
                  let normalized = RelayURL.normalized(raw) else { return nil }
            if !result.contains(normalized) { result.append(normalized) }
        }
        return result
    }

}

nonisolated struct AccountSetupAvatar: Sendable {
    let data: Data
    let mediaType: String
}

nonisolated enum AccountSetupPublication {
    static func publish(
        step: OnboardingStepFfi,
        propose: () async throws -> OnboardingSnapshotFfi,
        approve: (UInt64) async throws -> OnboardingSnapshotFfi
    ) async throws -> OnboardingSnapshotFfi {
        let proposed = try await propose()
        try Task.checkCancellation()
        guard let proposal = proposed.proposal, proposal.step == step,
              proposal.revision == proposed.revision,
              proposed.steps.first(where: { $0.step == step })?.actions.contains(.approveRepair) == true
        else { throw MarmotKitError.OnboardingActionUnavailable }
        return try await approve(proposed.revision)
    }
}

nonisolated enum AccountSetupPolicy {
    static func automaticAction(_ snapshot: OnboardingSnapshotFfi) -> AccountSetupCommand? {
        guard !snapshot.cancellationPending else { return nil }
        if let proposal = snapshot.proposal {
            guard proposal.step == .follows,
                  snapshot.steps.first(where: { $0.step == .follows })?.actions.contains(.cancelRepair) == true
            else { return nil }
            return .cancelRepair
        }
        guard let step = snapshot.steps.first(where: { $0.status != .passed && $0.status != .skipped }),
              step.step == .follows, step.actions.contains(.continueWithout) else { return nil }
        return .skip(.follows)
    }
}
