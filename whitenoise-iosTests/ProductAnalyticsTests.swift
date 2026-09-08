import Foundation
import MarmotKit
import Synchronization
import Testing
@testable import whitenoise_ios

@MainActor
final class DiagnosticsTestSource: DeviceDiagnosticsDataSource {
    var decision: UsageDiagnosticsDecisionFfi = .acceptanceRequired
    var audit = false
    var failSave = false
    var writes: [Bool] = []
    var previouslyEnabled = false
    var policy = ""

    func deviceDiagnosticsSnapshot() async throws -> DeviceDiagnosticsSnapshot? { snapshot }
    var snapshot: DeviceDiagnosticsSnapshot {
        DeviceDiagnosticsSnapshot(
            settings: UsageDiagnosticsSettingsFfi(decision: decision, policyRevision: policy, registryRevision: "registry", updatedAtMs: 0, previouslyEnabled: previouslyEnabled),
            status: UsageDiagnosticsStatusFfi(consent: decision, telemetry: .unconfigured, productAnalytics: .unconfigured, queuedEvents: 0, droppedEvents: 0, acceptedBatches: 0, failedBatches: 0),
            auditEnabled: audit
        )
    }
    func saveUsageDiagnosticsConsent(_ enabled: Bool) async throws -> DeviceDiagnosticsSnapshot {
        if failSave { throw CancellationError() }
        writes.append(enabled)
        decision = enabled ? .granted : .declined
        return snapshot
    }
    func saveDiagnosticLogging(_ enabled: Bool) async throws -> DeviceDiagnosticsSnapshot {
        if failSave { throw CancellationError() }
        audit = enabled
        return snapshot
    }
}

@MainActor
struct DeviceDiagnosticsConsentTests {
    @Test func firstLaunchDefaultsOffAndDeclinePersistsWithoutAnAccount() async {
        let source = DiagnosticsTestSource()
        let model = DeviceDiagnosticsConsent()
        #expect(!model.initialDecisionResolved)
        await model.reload(using: source)
        #expect(model.pending)
        #expect(!model.usageEnabled && !model.auditEnabled)
        #expect(await model.finishPrompt(using: source))
        #expect(source.writes == [false])
        let relaunched = DeviceDiagnosticsConsent()
        await relaunched.reload(using: source)
        #expect(relaunched.initialDecisionResolved && !relaunched.pending)
        #expect(!relaunched.canPresent(chatsVisible: true, anotherSheetVisible: false, runtimeReady: true))
    }

    @Test func explicitGrantSurvivesClosingAndAuditRemainsIndependent() async {
        let source = DiagnosticsTestSource()
        let model = DeviceDiagnosticsConsent()
        await model.reload(using: source)
        #expect(await model.setUsage(true, using: source))
        #expect(await model.finishPrompt(using: source))
        #expect(source.writes == [true])
        #expect(!source.audit)
        #expect(await model.setAudit(true, using: source))
        #expect(await model.setUsage(false, using: source))
        #expect(source.audit)
    }

    @Test func failedSaveCannotDismissOrPretendTheNewChoiceWasSaved() async {
        let source = DiagnosticsTestSource()
        let model = DeviceDiagnosticsConsent()
        await model.reload(using: source)
        source.failSave = true
        #expect(!(await model.setUsage(true, using: source)))
        #expect(model.errorMessage != nil)
        #expect(!model.initialDecisionResolved)
        #expect(!(await model.finishPrompt(using: source)))
        #expect(source.writes.isEmpty)
        source.failSave = false
        await model.reload(using: source)
        #expect(await model.finishPrompt(using: source))
    }

    @Test func migrationIgnoresOldSeenFlagAndDistinguishesScopeChanges() async throws {
        let name = "DiagnosticsReceiptTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "marmot.deviceDiagnosticsPromptSeen")
        let source = DiagnosticsTestSource()
        source.previouslyEnabled = true
        let model = DeviceDiagnosticsConsent(defaults: defaults)
        await model.reload(using: source)
        #expect(model.pending)
        let legacyExplanation = model.explanation
        #expect(legacyExplanation != nil)
        source.policy = "previous-policy"
        await model.reload(using: source)
        #expect(model.explanation != legacyExplanation)
        #expect(!model.canPresent(chatsVisible: true, anotherSheetVisible: true, runtimeReady: true))
        #expect(!model.canPresent(chatsVisible: true, anotherSheetVisible: false, runtimeReady: false))
        #expect(!model.canPresent(chatsVisible: true, anotherSheetVisible: false, runtimeReady: true, chatNavigationPending: true))
        model.reset()
        #expect(!model.initialDecisionResolved)
    }
}

struct ProductAnalyticsTests {
    @Test func delayedWorkCannotCrossConsentOrContextBoundaries() async {
        let events = Mutex<[String]>([])
        let recorder = ProductAnalyticsRecorder()
        let beforeConsent = recorder.ticket()
        recorder.replaceSink { event in events.withLock { $0.append(event.ffi.name) } }
        #expect(recorder.record(.screen(.onboarding), ticket: beforeConsent) == nil)
        let old = recorder.ticket()
        recorder.replaceSink(nil)
        recorder.replaceSink { event in events.withLock { $0.append(event.ffi.name) } }
        #expect(recorder.record(.screen(.conversation), ticket: old) == nil)
        await recorder.record(.screen(.inbox), ticket: recorder.ticket())?.value
        #expect(events.withLock { $0 } == ["app_screen_viewed"])
    }

    @Test func lifecycleRefreshPreservesCurrentObservationTickets() async {
        let recorder = ProductAnalyticsRecorder()
        let events = Mutex<[String]>([])
        recorder.activateSink { event in events.withLock { $0.append(event.ffi.name) } }
        let ticket = recorder.ticket()
        recorder.activateSink { event in events.withLock { $0.append(event.ffi.name) } }
        await recorder.record(.search(.success), ticket: ticket)?.value
        #expect(events.withLock { $0 } == ["app_message_search"])
        recorder.replaceSink(nil)
        recorder.activateSink { event in events.withLock { $0.append(event.ffi.name) } }
        #expect(recorder.record(.search(.success), ticket: ticket) == nil)
    }

    @Test func composeCountsOnceAndScannerCoverageIsNotCancellation() async {
        let recorder = ProductAnalyticsRecorder()
        let actions = Mutex<[String]>([])
        recorder.activateSink { event in actions.withLock { $0.append(event.ffi.properties[0].value) } }
        var interaction = ProductComposeObservation()
        await interaction.begin(using: recorder)?.value
        #expect(interaction.end(using: recorder, temporarilyCovered: true) == nil)
        #expect(interaction.begin(using: recorder) == nil)
        await interaction.end(using: recorder, temporarilyCovered: false)?.value
        #expect(interaction.end(using: recorder, temporarilyCovered: false) == nil)
        #expect(actions.withLock { $0 } == ["open", "cancel"])

        var completed = ProductComposeObservation()
        await completed.begin(using: recorder)?.value
        completed.complete()
        #expect(completed.end(using: recorder, temporarilyCovered: false) == nil)
        #expect(actions.withLock { $0 } == ["open", "cancel", "open"])
    }

    @Test func buildMetadataAndFlavorConfigurationAreIndependent() {
        let production = ProductAnalyticsBuildConfig.current(info: [
            "CFBundleShortVersionString": "2026.9.8", "CFBundleVersion": "33",
            "WhiteNoiseTelemetryEnvironment": "production",
            "WhiteNoiseProductAnalyticsAppKey": "A-SH-production",
            "WhiteNoiseTelemetryBearerToken": "otlp-only"
        ])
        let staging = ProductAnalyticsBuildConfig.current(info: [
            "WhiteNoiseTelemetryEnvironment": "staging",
            "WhiteNoiseProductAnalyticsAppKey": "$(STAGING_APTABASE_KEY_WHITENOISE_IOS)",
            "WhiteNoiseTelemetryBearerToken": "otlp-only"
        ])
        #expect(production.runtimeConfig.metadata.appVersion == "2026.9.8")
        #expect(production.runtimeConfig.metadata.environment == "production")
        #expect(staging.appKey == nil)
        #expect(staging.endpoint == nil)
        #expect(staging.environment == "staging")
        #expect(production.runtimeConfig.registry.isEmpty)
        #expect(!production.runtimeConfig.allowLoopback)
    }

    @Test @MainActor func deviceConsentWorksBeforeAnyProfileExists() async throws {
        let client = try MarmotClient.testClient()
        let defaultsName = "AccountFreeConsent.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let appState = AppState(client: client, notifications: AppNotifications(), accountDefaults: defaults, erasureDefaults: defaults)
        appState.setPhase(.onboarding)
        appState.setAppSceneActive(true)
        let original = try #require(try await appState.deviceDiagnosticsSnapshot())
        #expect(original.settings.decision == .acceptanceRequired)
        #expect(appState.activeAccountRef == nil)
        let granted = try await appState.saveUsageDiagnosticsConsent(true)
        #expect(granted.settings.decision == .granted)
        let oldAccountTicket = try #require(appState.productAnalytics.ticket())
        appState.activeAccountRef = "new-profile-context"
        #expect(appState.productAnalytics.record(.search(.success), ticket: oldAccountTicket) == nil)
        let logging = try await appState.saveDiagnosticLogging(true)
        #expect(logging.auditEnabled)
        let declined = try await appState.saveUsageDiagnosticsConsent(false)
        #expect(declined.auditEnabled && declined.settings.decision == .declined)
        try await client.marmot.shutdownAndClose()
    }

    @Test @MainActor func frozenRuntimeCannotRecordEvenWithStoredConsent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FrozenAnalytics-\(UUID())")
        let client = try MarmotClient(rootPath: root.path, relayUrls: [], cursorPersistence: .frozen)
        try client.marmot.setProductAnalyticsRuntimeConfig(config: ProductAnalyticsBuildConfig(
            endpoint: "https://analytics.invalid/api/v0/events", appKey: "A-SH-test",
            operatorLabel: "test", retentionDisclosure: nil, appVersion: "1", osMajorVersion: "27",
            deviceClass: "phone", environment: "staging", isDebug: true
        ).runtimeConfig)
        _ = try client.marmot.setUsageDiagnosticsConsent(enabled: true)
        try await client.marmot.setProductAnalyticsActivity(activity: .foreground)
        #expect(try client.marmot.recordProductEvent(event: ProductEvent.screen(.inbox).ffi) == .ignoredDisabled)
        #expect(try client.marmot.usageDiagnosticsStatus().queuedEvents == 0)
        _ = try client.marmot.setUsageDiagnosticsConsent(enabled: false)
        try await client.marmot.shutdownAndClose()
    }

    @Test func durationBucketsUseInclusiveBoundaries() {
        #expect(ProductEvent.durationBucket(10) == "le_10ms")
        #expect(ProductEvent.durationBucket(11) == "le_25ms")
        #expect(ProductEvent.durationBucket(3_600_000) == "le_60m")
        #expect(ProductEvent.durationBucket(.max) == "gt_60m")
    }

    @Test @MainActor func searchReportsOneInteractionAndNoTerms() async {
        let events = Mutex<[ProductEventFfi]>([])
        let recorder = ProductAnalyticsRecorder()
        recorder.replaceSink { event in events.withLock { $0.append(event.ffi) } }
        let search = ConversationSearchModel()
        search.analytics = recorder
        search.entriesProvider = { [.init(itemId: "row", messageIdHex: "message", text: "private content")] }
        search.activate()
        search.query = "pri"
        search.query = "private"
        search.refreshAfterTimelineChange()
        #expect(events.withLock { $0.isEmpty })
        await search.end()?.value
        #expect(search.end() == nil)
        let recorded = events.withLock { $0 }
        #expect(recorded.count == 1)
        #expect(recorded.first?.name == "app_message_search")
        #expect(recorded.first?.properties == [.init(name: "outcome", value: "success")])
    }

    @Test @MainActor func realCollectorAcceptsHostVocabularyAndRevokesBothPipelines() async throws {
        let client = try MarmotClient.testClient()
        let config = ProductAnalyticsBuildConfig(
            endpoint: "https://analytics.invalid/api/v0/events", appKey: "A-SH-test",
            operatorLabel: "test_operator", retentionDisclosure: nil,
            appVersion: "2026.9.8", osMajorVersion: "27", deviceClass: "phone", environment: "staging", isDebug: true
        )
        try client.marmot.setProductAnalyticsRuntimeConfig(config: config.runtimeConfig)
        #expect(try client.marmot.recordProductEvent(event: ProductEvent.screen(.inbox).ffi) == .ignoredDisabled)
        #expect(throws: MarmotKitError.self) { try client.marmot.telemetryInstallId() }
        _ = try client.marmot.setUsageDiagnosticsConsent(enabled: true)
        let firstID = try client.marmot.telemetryInstallId()
        try await client.marmot.setProductAnalyticsActivity(activity: .foreground)
        let events: [ProductEvent] = [
            .screen(.inbox), .onboarding(.identitySelection, .import, .success),
            .ready(success: true, milliseconds: 42), .compose(cancelled: false), .compose(cancelled: true),
            .search(.empty), .attachment(.picker, .cancelled), .attachment(.open, .failure),
            .attachment(.save, .success), .settings(.privacy), .permission(.granted)
        ]
        for event in events { #expect(try client.marmot.recordProductEvent(event: event.ffi) == .recorded) }
        let vocabulary: [ProductEvent] = ProductScreen.allCases.map(ProductEvent.screen)
            + ProductSettingsSection.allCases.map(ProductEvent.settings)
            + ProductSearchOutcome.allCases.map(ProductEvent.search)
            + ProductPermissionOutcome.allCases.map(ProductEvent.permission)
            + ProductAttachmentAction.allCases.flatMap { action in
                [ProductOutcome.success, .failure, .cancelled].map { .attachment(action, $0) }
            }
            + ProductOnboardingStep.allCases.flatMap { step in
                ProductOnboardingPath.allCases.flatMap { path in ProductOutcome.allCases.map { .onboarding(step, path, $0) } }
            }
        for event in vocabulary {
            let result = try client.marmot.recordProductEvent(event: event.ffi)
            #expect(result == .recorded || result == .ignoredDuplicate)
        }
        #expect(try client.marmot.recordProductEvent(event: ProductEvent.screen(.inbox).ffi) == .ignoredDuplicate)
        #expect(throws: MarmotKitError.self) {
            try client.marmot.recordProductEvent(event: ProductEventFfi(name: "app_message_search", properties: [.init(name: "query", value: "private")]))
        }
        let status = try client.marmot.usageDiagnosticsStatus()
        #expect(status.productAnalytics == .ready)
        #expect(status.telemetry == .unconfigured)
        _ = try client.marmot.setUsageDiagnosticsConsent(enabled: false)
        #expect(try client.marmot.usageDiagnosticsStatus().queuedEvents == 0)
        #expect(try client.marmot.usageDiagnosticsStatus().telemetry == .disabled)
        _ = try client.marmot.setUsageDiagnosticsConsent(enabled: true)
        #expect(try client.marmot.telemetryInstallId() != firstID)
        _ = try client.marmot.setUsageDiagnosticsConsent(enabled: false)
        try await client.marmot.shutdownAndClose()
    }
}
