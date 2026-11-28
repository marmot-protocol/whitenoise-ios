import Foundation
import MarmotKit
@testable import whitenoise_ios

func deviceLinkSnapshot(
    prompts: [DeviceLinkPromptFfi] = [],
    newDevice: NewDeviceLinkStateFfi? = nil
) -> DeviceLinkSnapshotFfi {
    DeviceLinkSnapshotFfi(newDevice: newDevice, prompts: prompts, moves: [], deviceGroupStalled: false, chatProgress: [])
}

/// Only the MDK boundary is replaced. The real store still captures the runtime,
/// acquires mutation leases, rejects stale reads and owns all presentation state.
@MainActor
final class DeviceLinkStoreFixture {
    let primary = accountSummary("primary", byte: "a1")
    let secondary = accountSummary("secondary", byte: "a2")
    let appState: AppState
    var snapshots: [String: DeviceLinkSnapshotFfi] = [:]
    var roster: [LinkedDeviceFfi] = []
    var closed: UInt32 = 0
    var leftover: UInt32 = 0
    var fresh = false
    var signIns: [UnrecognizedSignInFfi] = []
    var warnings: [CompromiseWarningItemFfi] = []
    var overdue = false
    var imports: [ChatHistoryImportFfi] = []
    var snapshotRead: ((String) async throws -> DeviceLinkSnapshotFfi)?
    var rosterRead: (() async throws -> [LinkedDeviceFfi])?
    var signInsRead: (() async throws -> [UnrecognizedSignInFfi])?
    var start: ((Marmot, String) async throws -> DeviceLinkSnapshotFfi)?
    var rotate: ((Marmot, String) async throws -> Void)?
    var approval: ((String, String, String, Bool, Bool) async throws -> DeviceLinkSnapshotFfi)?
    var rename: ((String, String, String) async throws -> Void)?
    var switchAccount: ((AppState, String) async -> Void)?

    init(client: MarmotClient, state: AppState? = nil) {
        appState = state ?? AppState.test(client: client)
        appState.setPhase(.ready)
        appState.setAppSceneActive(true)
        appState.accountStore.accounts = [primary, secondary]
        appState.activeAccountRef = primary.label
    }

    func makeStore() -> DeviceLinkStore {
        var calls = DeviceLinkCalls()
        calls.linkedDevices = { _, _ in
            if let read = self.rosterRead { return try await read() }
            return self.roster
        }
        calls.chatsClosed = { _, _ in self.closed }
        calls.leftoverChats = { _, _ in self.leftover }
        calls.startedFresh = { _, _ in self.fresh }
        calls.signIns = { _, _ in
            if let read = self.signInsRead { return try await read() }
            return self.signIns
        }
        calls.compromiseWarning = { _, _ in self.warnings }
        calls.keyPackageOverdue = { _, _ in self.overdue }
        calls.historyImports = { _, _ in self.imports }
        calls.startLink = { marmot, account in
            if let start = self.start { return try await start(marmot, account) }
            preconditionFailure("Unexpected startDeviceLink")
        }
        calls.rotateKeyPackage = { marmot, account in
            guard let rotate = self.rotate else { preconditionFailure("Unexpected rotateKeyPackage") }
            try await rotate(marmot, account)
        }
        calls.link = { _, account, prompt, label, chats, history in
            guard let approval = self.approval else { preconditionFailure("Unexpected linkDevice") }
            return try await approval(account, prompt, label, chats, history)
        }
        calls.rename = { _, account, slot, label in
            guard let rename = self.rename else { preconditionFailure("Unexpected renameLinkedDevice") }
            try await rename(account, slot, label)
        }
        calls.activateAccount = { state, account in
            if let switchAccount = self.switchAccount { await switchAccount(state, account) }
            else { state.activeAccountRef = account }
        }
        return DeviceLinkStore(calls: calls) { _, account in
            try await self.readSnapshot(account)
        }
    }

    private func readSnapshot(_ account: String) async throws -> DeviceLinkSnapshotFfi {
        if let read = snapshotRead { return try await read(account) }
        return snapshots[account] ?? deviceLinkSnapshot()
    }
}
