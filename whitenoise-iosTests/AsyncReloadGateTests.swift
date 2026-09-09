import Foundation
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

@MainActor
struct AsyncReloadGateTests {
    @Test func privacyReloadStartedBeforeAuditSaveDoesNotOverwriteSavedToggle() async {
        let model = PrivacySecuritySettingsViewModel()
        let dataSource = PrivacySecuritySettingsDataSourceStub()
        let staleProjection = privacyProjection(auditEnabled: false)
        let currentProjection = privacyProjection(auditEnabled: true)
        dataSource.projectionResponses = [.suspended, .immediate(currentProjection)]
        model.usageEnabled = false
        model.auditSettings = PrivacyAuditSettingsProjection(enabled: false)

        let reloadTask = Task { @MainActor in
            await model.reload(using: dataSource)
        }
        await dataSource.waitUntilProjectionCallCount(1)

        await model.setAuditEnabled(true, using: dataSource)
        #expect(model.auditSettings?.enabled == true)

        dataSource.completeNextProjection(with: staleProjection)
        await reloadTask.value

        #expect(dataSource.projectionCallCount == 2)
        #expect(model.auditSettings?.enabled == true)
    }

    @Test func relayReloadStartedBeforeSaveDoesNotRevertSavedList() async {
        let model = RelaysViewModel()
        let dataSource = RelaysViewModelDataSourceStub()
        let staleLists = relayLists(["wss://old.example"])
        let savedLists = relayLists(["wss://new.example"])
        model.lists = staleLists
        dataSource.loadResponses = [.suspended, .immediate(savedLists)]
        dataSource.saveResponses = [.immediate(savedLists)]

        let reloadTask = Task { @MainActor in
            await model.reload(using: dataSource)
        }
        await dataSource.waitUntilLoadCallCount(1)

        let saved = await model.save(["wss://new.example"], using: dataSource)
        #expect(saved)
        #expect(model.currentRelays == ["wss://new.example"])

        dataSource.completeNextLoad(with: staleLists)
        await reloadTask.value

        #expect(dataSource.loadCallCount == 2)
        #expect(model.currentRelays == ["wss://new.example"])
    }

    @Test func relaySaveRejectsRetiredEndpointBeforePublishing() async {
        let model = RelaysViewModel()
        let dataSource = RelaysViewModelDataSourceStub()
        model.lists = relayLists(["wss://old.example"])
        dataSource.classify = { endpoints in
            endpoints.map {
                RelayEndpointClassificationFfi(
                    endpoint: $0,
                    normalizedEndpoint: $0,
                    policy: .retired
                )
            }
        }

        let saved = await model.save(["wss://relay.damus.io"], using: dataSource)

        #expect(!saved)
        #expect(dataSource.saveCallCount == 0)
        #expect(dataSource.classificationRequests == [["wss://relay.damus.io"]])
        #expect(model.saveError?.contains("retired") == true)
    }

    @Test func relaySaveUsesMdkCanonicalEndpoint() async {
        let model = RelaysViewModel()
        let dataSource = RelaysViewModelDataSourceStub()
        model.lists = relayLists(["wss://old.example"])
        dataSource.classify = { endpoints in
            endpoints.map {
                RelayEndpointClassificationFfi(
                    endpoint: $0,
                    normalizedEndpoint: $0 + "/",
                    policy: .allowed
                )
            }
        }

        let saved = await model.save(["wss://new.example"], using: dataSource)

        #expect(saved)
        #expect(dataSource.saveRequests == [["wss://new.example/"]])
    }

    @Test func relaySwipeDeleteQueuesSecondDeleteAgainstPostSaveList() async {
        let model = RelaysViewModel()
        let dataSource = RelaysViewModelDataSourceStub()
        model.lists = relayLists([
            "wss://a.example",
            "wss://b.example",
            "wss://c.example",
        ])
        dataSource.saveResponses = [.suspended, .suspended]

        model.deleteRelays(at: IndexSet(integer: 0), using: dataSource)
        await dataSource.waitUntilSaveCallCount(1)

        model.deleteRelays(at: IndexSet(integer: 1), using: dataSource)
        #expect(dataSource.saveRequests == [["wss://b.example", "wss://c.example"]])

        dataSource.completeNextSave(with: relayLists(["wss://b.example", "wss://c.example"]))
        await dataSource.waitUntilSaveCallCount(2)

        #expect(dataSource.saveRequests == [
            ["wss://b.example", "wss://c.example"],
            ["wss://c.example"],
        ])

        dataSource.completeNextSave(with: relayLists(["wss://c.example"]))
        await dataSource.waitUntilPresentedToastCount(2)

        #expect(model.currentRelays == ["wss://c.example"])
    }

    @Test func failedQueuedRelayDeleteRetriesAfterNextSuccessfulSave() async {
        let model = RelaysViewModel()
        let dataSource = RelaysViewModelDataSourceStub()
        model.lists = relayLists([
            "wss://a.example",
            "wss://b.example",
            "wss://c.example",
        ])
        dataSource.saveResponses = [
            .suspended,
            .suspended,
            .immediate(relayLists([
                "wss://b.example",
                "wss://c.example",
            ])),
            .immediate(relayLists([
                "wss://c.example",
            ])),
        ]

        model.deleteRelays(at: IndexSet(integer: 0), using: dataSource)
        await dataSource.waitUntilSaveCallCount(1)

        model.deleteRelays(at: IndexSet(integer: 1), using: dataSource)
        dataSource.completeNextSave(with: relayLists([
            "wss://b.example",
            "wss://c.example",
        ]))
        await dataSource.waitUntilSaveCallCount(2)

        #expect(dataSource.saveRequests == [
            ["wss://b.example", "wss://c.example"],
            ["wss://c.example"],
        ])
        #expect(model.currentRelays == ["wss://b.example", "wss://c.example"])

        dataSource.failNextSave(with: RelaysViewModelDataSourceStub.SaveError())
        await dataSource.waitUntilPresentedToastCount(2)
        #expect(model.saveError == "Save failed")

        let saved = await model.save([
            "wss://b.example",
            "wss://c.example",
        ], using: dataSource)

        #expect(saved)
        #expect(dataSource.saveRequests == [
            ["wss://b.example", "wss://c.example"],
            ["wss://c.example"],
            ["wss://b.example", "wss://c.example"],
            ["wss://c.example"],
        ])
        #expect(model.currentRelays == ["wss://c.example"])
    }

    @Test func failedQueuedRelayDeleteDoesNotRemoveRelayReintroducedByNewerSave() async {
        let model = RelaysViewModel()
        let dataSource = RelaysViewModelDataSourceStub()
        model.lists = relayLists([
            "wss://a.example",
            "wss://b.example",
            "wss://c.example",
        ])
        dataSource.saveResponses = [
            .suspended,
            .suspended,
            .immediate(relayLists([
                "wss://b.example",
                "wss://c.example",
                "wss://d.example",
            ])),
        ]

        model.deleteRelays(at: IndexSet(integer: 0), using: dataSource)
        await dataSource.waitUntilSaveCallCount(1)

        model.deleteRelays(at: IndexSet(integer: 1), using: dataSource)
        dataSource.completeNextSave(with: relayLists([
            "wss://b.example",
            "wss://c.example",
        ]))
        await dataSource.waitUntilSaveCallCount(2)

        dataSource.failNextSave(with: RelaysViewModelDataSourceStub.SaveError())
        await dataSource.waitUntilPresentedToastCount(2)

        let saved = await model.save([
            "wss://b.example",
            "wss://c.example",
            "wss://d.example",
        ], using: dataSource)

        #expect(saved)
        #expect(dataSource.saveRequests == [
            ["wss://b.example", "wss://c.example"],
            ["wss://c.example"],
            ["wss://b.example", "wss://c.example", "wss://d.example"],
        ])
        #expect(model.currentRelays == ["wss://b.example", "wss://c.example", "wss://d.example"])
    }
}

@MainActor
private final class PrivacySecuritySettingsDataSourceStub: PrivacySecuritySettingsViewModelDataSource {
    var activeAccountRef: String? = "account-1"
    var projectionResponses: [SuspendingResponse<PrivacySecuritySettingsProjection?>] = []
    private(set) var projectionCallCount = 0

    private var projectionWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var projectionContinuations: [CheckedContinuation<PrivacySecuritySettingsProjection?, Error>] = []

    func privacySecuritySettingsProjection() async throws -> PrivacySecuritySettingsProjection? {
        projectionCallCount += 1
        resumeProjectionWaiters()
        guard !projectionResponses.isEmpty else { return nil }
        switch projectionResponses.removeFirst() {
        case .immediate(let projection):
            return projection
        case .suspended:
            return try await withCheckedThrowingContinuation { continuation in
                projectionContinuations.append(continuation)
            }
        }
    }

    func auditLogFileRows() async throws -> [AuditFileRow]? {
        []
    }

    func deleteAllAuditLogFiles() async throws {}

    func setAuditLogEnabled(_ enabled: Bool) async throws -> AuditLogSettingsFfi {
        AuditLogSettingsFfi(enabled: enabled)
    }

    func waitUntilProjectionCallCount(_ count: Int) async {
        guard projectionCallCount < count else { return }
        await withCheckedContinuation { continuation in
            projectionWaiters.append((count, continuation))
        }
    }

    func completeNextProjection(with projection: PrivacySecuritySettingsProjection?) {
        projectionContinuations.removeFirst().resume(returning: projection)
    }

    private func resumeProjectionWaiters() {
        let ready = projectionWaiters.filter { projectionCallCount >= $0.0 }
        projectionWaiters.removeAll { projectionCallCount >= $0.0 }
        ready.forEach { $0.1.resume() }
    }
}

@MainActor
private final class RelaysViewModelDataSourceStub: RelaysViewModelDataSource {
    struct SaveError: LocalizedError {
        var errorDescription: String? { "Save failed" }
    }

    var activeAccountRef: String? = "account-1"
    var loadResponses: [SuspendingResponse<AccountRelayListsFfi>] = []
    var saveResponses: [SuspendingResponse<AccountRelayListsFfi>] = []
    var classify: (([String]) -> [RelayEndpointClassificationFfi])?
    private(set) var loadCallCount = 0
    private(set) var saveCallCount = 0
    private(set) var classificationRequests: [[String]] = []
    private(set) var saveRequests: [[String]] = []
    private(set) var presentedToasts: [Toast] = []

    private var loadWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var saveWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var toastWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var loadContinuations: [CheckedContinuation<AccountRelayListsFfi, Error>] = []
    private var saveContinuations: [CheckedContinuation<AccountRelayListsFfi, Error>] = []

    func loadAccountRelayLists(accountRef _: String) async throws -> AccountRelayListsFfi {
        loadCallCount += 1
        resumeLoadWaiters()
        guard !loadResponses.isEmpty else { return relayLists([]) }
        switch loadResponses.removeFirst() {
        case .immediate(let lists):
            return lists
        case .suspended:
            return try await withCheckedThrowingContinuation { continuation in
                loadContinuations.append(continuation)
            }
        }
    }

    func classifyRelayEndpoints(
        _ endpoints: [String]
    ) async throws -> [RelayEndpointClassificationFfi] {
        classificationRequests.append(endpoints)
        if let classify {
            return classify(endpoints)
        }
        return endpoints.map {
            RelayEndpointClassificationFfi(
                endpoint: $0,
                normalizedEndpoint: $0,
                policy: .allowed
            )
        }
    }

    func saveAccountRelayLists(
        accountRef _: String,
        relays: [String],
        currentLists _: AccountRelayListsFfi?
    ) async throws -> AccountRelayListsFfi {
        saveCallCount += 1
        saveRequests.append(relays)
        resumeSaveWaiters()
        guard !saveResponses.isEmpty else { return relayLists(relays) }
        switch saveResponses.removeFirst() {
        case .immediate(let lists):
            return lists
        case .suspended:
            return try await withCheckedThrowingContinuation { continuation in
                saveContinuations.append(continuation)
            }
        }
    }

    func present(_ toast: Toast) {
        presentedToasts.append(toast)
        resumeToastWaiters()
    }

    func waitUntilLoadCallCount(_ count: Int) async {
        guard loadCallCount < count else { return }
        await withCheckedContinuation { continuation in
            loadWaiters.append((count, continuation))
        }
    }

    func waitUntilSaveCallCount(_ count: Int) async {
        guard saveCallCount < count else { return }
        await withCheckedContinuation { continuation in
            saveWaiters.append((count, continuation))
        }
    }

    func waitUntilPresentedToastCount(_ count: Int) async {
        guard presentedToasts.count < count else { return }
        await withCheckedContinuation { continuation in
            toastWaiters.append((count, continuation))
        }
    }

    func completeNextLoad(with lists: AccountRelayListsFfi) {
        loadContinuations.removeFirst().resume(returning: lists)
    }

    func completeNextSave(with lists: AccountRelayListsFfi) {
        saveContinuations.removeFirst().resume(returning: lists)
    }

    func failNextSave(with error: any Error) {
        saveContinuations.removeFirst().resume(throwing: error)
    }

    private func resumeLoadWaiters() {
        let ready = loadWaiters.filter { loadCallCount >= $0.0 }
        loadWaiters.removeAll { loadCallCount >= $0.0 }
        ready.forEach { $0.1.resume() }
    }

    private func resumeSaveWaiters() {
        let ready = saveWaiters.filter { saveCallCount >= $0.0 }
        saveWaiters.removeAll { saveCallCount >= $0.0 }
        ready.forEach { $0.1.resume() }
    }

    private func resumeToastWaiters() {
        let ready = toastWaiters.filter { presentedToasts.count >= $0.0 }
        toastWaiters.removeAll { presentedToasts.count >= $0.0 }
        ready.forEach { $0.1.resume() }
    }
}

private enum SuspendingResponse<Value> {
    case immediate(Value)
    case suspended
}

private func privacyProjection(auditEnabled: Bool) -> PrivacySecuritySettingsProjection {
    PrivacySecuritySettingsProjection(
        usageEnabled: false,
        auditSettings: PrivacyAuditSettingsProjection(enabled: auditEnabled),
        auditFileRows: []
    )
}

private func relayLists(_ relays: [String]) -> AccountRelayListsFfi {
    AccountRelayListsFfi(
        complete: true,
        missing: [],
        defaultRelays: relays,
        bootstrapRelays: relays,
        nip65: RelayListFfi(kind: 10_002, relays: relays),
        inbox: RelayListFfi(kind: 10_050, relays: relays)
    )
}
