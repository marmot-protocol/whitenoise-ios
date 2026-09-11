import SwiftUI
import MarmotKit

@MainActor
protocol RelaysViewModelDataSource: AnyObject {
    var activeAccountRef: String? { get }

    func loadAccountRelayLists(accountRef: String) async throws -> AccountRelayListsFfi
    func classifyRelayEndpoints(_ endpoints: [String]) async throws -> [RelayEndpointClassificationFfi]
    func saveAccountRelayLists(
        accountRef: String,
        relays: [String],
        currentLists: AccountRelayListsFfi?
    ) async throws -> AccountRelayListsFfi
    func present(_ toast: Toast)
}

extension AppState: RelaysViewModelDataSource {
    func loadAccountRelayLists(accountRef: String) async throws -> AccountRelayListsFfi {
        try await currentMarmotClient().accountRelayLists(accountRef: accountRef)
    }

    func classifyRelayEndpoints(_ endpoints: [String]) async throws -> [RelayEndpointClassificationFfi] {
        let client = try currentMarmotClient()
        return await client.classifyRelayEndpoints(endpoints)
    }

    func saveAccountRelayLists(
        accountRef: String,
        relays: [String],
        currentLists: AccountRelayListsFfi?
    ) async throws -> AccountRelayListsFfi {
        let client = try currentMarmotClient()
        return try await RelaySettings.saveAccountRelays(
            accountRef: accountRef,
            relays: relays,
            currentLists: currentLists,
            manager: client
        )
    }
}

nonisolated enum RelayEndpointPreflight {
    struct Rejection: LocalizedError {
        let policy: RelayEndpointPolicyFfi?
        let endpoint: String?

        var errorDescription: String? {
            let display = endpoint.flatMap {
                ContentSanitizer.relayDisplayLine($0, maxLength: 120)
            }
            switch policy {
            case .retired:
                return display.map { L10n.formatted("%@ is a retired relay.", $0) }
                    ?? L10n.string("That relay is retired.")
            case .unsafe:
                return display.map { L10n.formatted("%@ isn't safe to connect to.", $0) }
                    ?? L10n.string("That relay isn't safe to connect to.")
            case .invalid:
                return display.map { L10n.formatted("%@ isn't a valid relay URL.", $0) }
                    ?? L10n.string("That isn't a valid relay URL.")
            case .allowed, nil:
                return L10n.string("Relay validation returned an incomplete result.")
            }
        }
    }

    static func validatedRelays(
        inputs: [String],
        classifications: [RelayEndpointClassificationFfi]
    ) throws -> [String] {
        guard classifications.count == inputs.count else {
            throw Rejection(policy: nil, endpoint: nil)
        }

        var seen = Set<String>()
        var relays: [String] = []
        for (input, classification) in zip(inputs, classifications) {
            guard classification.endpoint == input else {
                throw Rejection(policy: nil, endpoint: nil)
            }
            guard classification.policy == .allowed else {
                throw Rejection(policy: classification.policy, endpoint: input)
            }
            guard let normalized = classification.normalizedEndpoint,
                  seen.insert(normalized).inserted
            else {
                if classification.normalizedEndpoint == nil {
                    throw Rejection(policy: nil, endpoint: input)
                }
                continue
            }
            relays.append(normalized)
        }
        return relays
    }
}

/// Screen store for `RelaysView`. Holds the relay-editing UI state and routes
/// reads/edits through Marmot (off the MainActor via `MarmotClient`), so the
/// view is pure rendering. The relay projection + validation live in the pure
/// `RelaySettings` helpers; this just orchestrates load/save and UI state.
///
/// Methods take an AppState-compatible data source rather than retaining it —
/// the view always has AppState via `@Environment`, and tests can drive the
/// async/reload interleavings without constructing a Marmot runtime.
@MainActor
@Observable
final class RelaysViewModel {
    private struct QueuedRelayDelete {
        var urls: [String]
        let accountRef: String
        let expectedRelays: [String]?

        func canApply(accountRef: String?, relays: [String]) -> Bool {
            guard self.accountRef == accountRef else { return false }
            guard let expectedRelays else { return true }
            return expectedRelays == relays
        }
    }

    var lists: AccountRelayListsFfi?
    var pendingUrl = ""
    @ObservationIgnored private var actionTasks: [UUID: Task<Void, Never>] = [:]

    deinit {
        for task in actionTasks.values { task.cancel() }
    }
    var saveError: String?
    var savedAt: Date?
    var loadError: String?

    private var actionGate = AsyncActionGate()
    private var reloadRequestedAfterSave = false
    private var queuedRelayDeletes: [QueuedRelayDelete] = []

    var isSaving: Bool { actionGate.isRunning }

    var currentRelays: [String] {
        guard let lists else { return [] }
        return RelaySettings.editableRelays(from: lists)
    }

    var canAdd: Bool {
        guard lists != nil,
              !isSaving,
              let normalized = RelaySettings.normalizedRelayURL(pendingUrl)
        else { return false }
        return !currentRelays.contains(normalized)
    }

    private func requestReloadAfterSave() {
        reloadRequestedAfterSave = true
    }

    private func drainDeferredReload(using dataSource: any RelaysViewModelDataSource) async {
        guard reloadRequestedAfterSave else { return }
        reloadRequestedAfterSave = false
        await reload(using: dataSource)
    }

    private func deferOrReload(using dataSource: any RelaysViewModelDataSource) async {
        if actionGate.isRunning {
            requestReloadAfterSave()
        } else {
            await reload(using: dataSource)
        }
    }

    private func canApplyReload(
        startedAt ticket: Int,
        accountRef: String?,
        using dataSource: any RelaysViewModelDataSource
    ) -> Bool {
        actionGate.canApplyReload(startedAt: ticket) && dataSource.activeAccountRef == accountRef
    }

    func reload(using dataSource: any RelaysViewModelDataSource) async {
        guard let reloadTicket = actionGate.reloadTicket() else {
            requestReloadAfterSave()
            return
        }
        let accountRef = dataSource.activeAccountRef
        guard let ref = accountRef else {
            lists = nil
            loadError = nil
            return
        }
        do {
            let loadedLists = try await dataSource.loadAccountRelayLists(accountRef: ref)
            guard canApplyReload(startedAt: reloadTicket, accountRef: accountRef, using: dataSource) else {
                await deferOrReload(using: dataSource)
                return
            }
            lists = loadedLists
            loadError = nil
        } catch {
            guard canApplyReload(startedAt: reloadTicket, accountRef: accountRef, using: dataSource) else {
                await deferOrReload(using: dataSource)
                return
            }
            // Keep the last-known list on a transient reload failure rather than
            // blanking an already-loaded screen back to the loading state.
            if lists == nil {
                loadError = UserFacingError.message(for: error)
            }
        }
    }

    func addPending(using dataSource: any RelaysViewModelDataSource) {
        guard let normalized = RelaySettings.normalizedRelayURL(pendingUrl), canAdd else { return }
        trackActionTask { [weak self] in
            guard let self else { return }
            if await self.save(self.currentRelays + [normalized], using: dataSource) {
                self.pendingUrl = ""
            }
        }
    }

    func deleteRelays(at indexSet: IndexSet, using dataSource: any RelaysViewModelDataSource) {
        let relays = currentRelays
        let urls = indexSet.compactMap { index in
            relays.indices.contains(index) ? relays[index] : nil
        }
        guard !urls.isEmpty else { return }
        if isSaving {
            queueRelayDeletes(urls, using: dataSource)
            return
        }
        trackActionTask { [weak self] in
            guard let self else { return }
            _ = await self.deleteRelayURLs(urls, using: dataSource)
        }
    }

    /// Fire-and-forget UI actions get tracked, weakly-capturing tasks so a
    /// dismissed screen doesn't stay alive issuing relay-save FFI; `deinit`
    /// cancels whatever is still in flight.
    private func trackActionTask(_ operation: @escaping @MainActor () async -> Void) {
        let id = UUID()
        actionTasks[id] = Task { @MainActor [weak self] in
            await operation()
            self?.actionTasks[id] = nil
        }
    }

    @discardableResult
    func save(_ relays: [String], using dataSource: any RelaysViewModelDataSource) async -> Bool {
        // Serialize saves: an overlapping save would compute its next list from
        // stale `lists`/`currentRelays` and clobber the in-flight write.
        guard actionGate.tryBegin() else { return false }
        guard let accountRef = dataSource.activeAccountRef else {
            actionGate.end()
            await drainDeferredReload(using: dataSource)
            return false
        }
        let locallyNormalized = RelaySettings.normalizedRelayURLs(relays)
        guard !locallyNormalized.isEmpty else {
            actionGate.end()
            await drainDeferredReload(using: dataSource)
            saveError = L10n.string("Keep at least one relay.")
            Haptics.error()
            return false
        }

        saveError = nil

        do {
            let classifications = try await dataSource.classifyRelayEndpoints(locallyNormalized)
            let normalized = try RelayEndpointPreflight.validatedRelays(
                inputs: locallyNormalized,
                classifications: classifications
            )
            guard !normalized.isEmpty else {
                throw RelayEndpointPreflight.Rejection(policy: nil, endpoint: nil)
            }
            guard dataSource.activeAccountRef == accountRef else {
                requestReloadAfterSave()
                actionGate.end()
                await drainDeferredReload(using: dataSource)
                return false
            }
            let savedLists = try await dataSource.saveAccountRelayLists(
                accountRef: accountRef,
                relays: normalized,
                currentLists: lists
            )
            guard dataSource.activeAccountRef == accountRef else {
                requestReloadAfterSave()
                actionGate.end()
                await drainDeferredReload(using: dataSource)
                return false
            }
            lists = savedLists
            savedAt = Date()
            Haptics.success()
            dataSource.present(.success(L10n.string("Relay lists updated")))
            actionGate.end()
            await drainQueuedRelayDeletes(using: dataSource)
            await drainDeferredReload(using: dataSource)
            return true
        } catch {
            if let failure = error as? RelaySettingsSaveFailure,
               let reloadedLists = failure.reloadedLists {
                lists = reloadedLists
            }
            Haptics.error()
            saveError = UserFacingError.message(for: error)
            dataSource.present(UserFacingError.toast(title: L10n.string("Relay update failed"), error: error))
            actionGate.end()
            await drainDeferredReload(using: dataSource)
            return false
        }
    }

    private func queueRelayDeletes(
        _ urls: [String],
        using dataSource: any RelaysViewModelDataSource,
        expectedRelays: [String]? = nil
    ) {
        guard let accountRef = dataSource.activeAccountRef else { return }
        if let index = queuedRelayDeletes.firstIndex(
            where: { $0.accountRef == accountRef && $0.expectedRelays == expectedRelays }
        ) {
            for url in urls where !queuedRelayDeletes[index].urls.contains(url) {
                queuedRelayDeletes[index].urls.append(url)
            }
        } else {
            queuedRelayDeletes.append(
                QueuedRelayDelete(
                    urls: urls,
                    accountRef: accountRef,
                    expectedRelays: expectedRelays
                )
            )
        }
    }

    @discardableResult
    private func deleteRelayURLs(_ urls: [String], using dataSource: any RelaysViewModelDataSource) async -> Bool {
        guard !isSaving else {
            queueRelayDeletes(urls, using: dataSource)
            return false
        }
        let deleteSet = Set(urls)
        let relays = currentRelays
        let next = relays.filter { !deleteSet.contains($0) }
        guard next != relays else { return true }
        return await save(next, using: dataSource)
    }

    private func drainQueuedRelayDeletes(using dataSource: any RelaysViewModelDataSource) async {
        guard !queuedRelayDeletes.isEmpty else { return }
        let deletes = queuedRelayDeletes
        queuedRelayDeletes.removeAll()
        for queuedDelete in deletes {
            let relays = currentRelays
            guard queuedDelete.canApply(
                accountRef: dataSource.activeAccountRef,
                relays: relays
            ) else { continue }
            let deleted = await deleteRelayURLs(queuedDelete.urls, using: dataSource)
            if !deleted {
                queueRelayDeletes(
                    queuedDelete.urls,
                    using: dataSource,
                    expectedRelays: relays
                )
            }
        }
    }
}
