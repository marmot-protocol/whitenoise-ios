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
    var runtimeAvailable = true

    func deviceDiagnosticsSnapshot() async throws -> DeviceDiagnosticsSnapshot? { runtimeAvailable ? snapshot : nil }
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
    @Test func unavailableRuntimeReadOffersRetryAndReloadsWhenReady() async {
        let source = DiagnosticsTestSource()
        let model = DeviceDiagnosticsConsent()
        source.runtimeAvailable = false
        await model.reload(using: source)
        #expect(model.errorMessage != nil)
        #expect(!model.initialDecisionResolved)
        #expect(!model.loading)
        source.runtimeAvailable = true
        await model.reload(using: source)
        #expect(model.errorMessage == nil)
        #expect(model.pending)
        #expect(await model.finishPrompt(using: source))
        #expect(model.initialDecisionResolved)
        #expect(source.writes == [false])
    }

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

    @Test func migrationExplanationDistinguishesLegacyOptInFromScopeChanges() async {
        let source = DiagnosticsTestSource()
        source.previouslyEnabled = true
        let model = DeviceDiagnosticsConsent()
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
    @Test func retentionDisclosureUsesTheSelectedLanguageWithoutChangingPolicy() {
        var config = ProductAnalyticsBuildConfig.current(info: [
            "WhiteNoiseProductAnalyticsRetention": "Usage analytics are scheduled for automatic deletion after 180 days."
        ])
        AppLanguage.$testCurrentOverride.withValue(.italian) {
            #expect(config.localizedRetentionDisclosure == "L’eliminazione automatica dei dati di analisi dell’utilizzo è programmata dopo 180 giorni.")
            #expect(config.retentionDisclosure == "Usage analytics are scheduled for automatic deletion after 180 days.")
            config.retentionDisclosure = "A different verified deployment policy."
            #expect(config.localizedRetentionDisclosure == "A different verified deployment policy.")
            config.retentionDisclosure = nil
            #expect(config.localizedRetentionDisclosure == nil)
        }
    }

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
        #expect(production.runtimeConfig.registry.map(\.name) == ProductTimingStage.allCases.map(\.rawValue))
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
        #expect(try client.marmot.recordHostTiming(
            name: ProductTimingStage.inboxBatch.rawValue, durationMs: 250, outcome: .success
        ) == .ignoredDisabled)
        #expect(try client.marmot.usageDiagnosticsStatus().queuedEvents == 0)
        _ = try client.marmot.setUsageDiagnosticsConsent(enabled: false)
        try await client.marmot.shutdownAndClose()
    }

    @Test(arguments: [false, true]) @MainActor
    func receiptSurvivesRuntimeReplacementAndErasureRestoresEligibility(granted: Bool) async throws {
        let original = try MarmotClient.testClient()
        let root = URL(fileURLWithPath: original.rootPath)
        let expected: UsageDiagnosticsDecisionFfi = granted ? .granted : .declined
        _ = try await original.setUsageDiagnosticsConsent(granted)
        try await original.marmot.setAuditLogSettings(settings: .init(enabled: true))
        try await original.marmot.shutdownAndClose()

        let reopened = try MarmotClient(rootPath: root.path, relayUrls: [])
        let stored = try await reopened.deviceDiagnosticsSnapshot()
        #expect(stored.settings.decision == expected)
        #expect(stored.auditEnabled)
        #expect(try await reopened.listAccounts().isEmpty)
        try await reopened.marmot.shutdownAndClose()

        try AppDataErasure.eraseClosedRuntime(at: root)
        let erased = try MarmotClient(rootPath: root.path, relayUrls: [])
        let reset = try await erased.deviceDiagnosticsSnapshot()
        #expect(reset.settings.decision == .acceptanceRequired)
        #expect(!reset.auditEnabled)
        try await erased.marmot.shutdownAndClose()
    }

    @Test func timingConsentAndDuration() async throws {
        let recorder = ProductAnalyticsRecorder()
        let events = Mutex<[(ProductTimingStage, UInt64, HostPerformanceOutcomeFfi)]>([])
        let start = ContinuousClock.now
        let beforeConsent = recorder.beginTiming(at: start)
        recorder.activateSink(timing: { stage, milliseconds, outcome in
            events.withLock { $0.append((stage, milliseconds, outcome)) }
        }) { _ in }
        #expect(recorder.recordTiming(.inboxBatch, since: beforeConsent) == nil)
        let timing = try #require(recorder.beginTiming(at: start))
        await recorder.recordTiming(.inboxBatch, since: timing, at: start.advanced(by: .milliseconds(250)))?.value
        await recorder.recordTiming(
            .libraryPrepare, since: timing, outcome: .failure, at: start.advanced(by: .milliseconds(251))
        )?.value
        let recorded = events.withLock { $0 }
        #expect(recorded.map { $0.0 } == [.inboxBatch, .libraryPrepare])
        #expect(recorded.map { $0.1 } == [250, 251])
        #expect(recorded.map { $0.2 } == [.success, .failure])
        recorder.replaceSink(nil)
        recorder.activateSink(timing: { stage, milliseconds, outcome in
            events.withLock { $0.append((stage, milliseconds, outcome)) }
        }) { _ in }
        #expect(recorder.recordTiming(.inboxBatch, since: timing) == nil)
        #expect(events.withLock { $0.count } == 2)
    }

    @Test func timingClampsEarlierCompletionAndTruncatesSubmillisecondDuration() async throws {
        let recorder = ProductAnalyticsRecorder()
        let durations = Mutex<[UInt64]>([])
        recorder.activateSink(timing: { _, milliseconds, _ in durations.withLock { $0.append(milliseconds) } }) { _ in }
        let start = ContinuousClock.now
        let timing = try #require(recorder.beginTiming(at: start))
        await recorder.recordTiming(.timelineWindow, since: timing, at: start.advanced(by: .milliseconds(-1)))?.value
        await recorder.recordTiming(.timelineWindow, since: timing, at: start.advanced(by: .microseconds(1_999)))?.value
        #expect(durations.withLock { $0 } == [0, 1])
    }

    @Test func rejectedTimingSinkStopsRecording() async throws {
        let recorder = ProductAnalyticsRecorder()
        recorder.activateSink(timing: { _, _, _ in throw CancellationError() }) { _ in }
        let timing = try #require(recorder.beginTiming())
        await recorder.recordTiming(.timelineWindow, since: timing)?.value
        #expect(recorder.ticket() == nil)
        recorder.activateSink(timing: { _, _, _ in }) { _ in }
        #expect(recorder.recordTiming(.timelineWindow, since: timing) == nil)
    }

    @Test func timingRequiresItsOwnSinkAndBypassesProductEvents() async throws {
        let recorder = ProductAnalyticsRecorder()
        let events = Mutex<[String]>([])
        let stages = Mutex<[ProductTimingStage]>([])
        recorder.activateSink { event in events.withLock { $0.append(event.ffi.name) } }
        #expect(recorder.beginTiming() == nil)
        recorder.activateSink(timing: { stage, _, _ in stages.withLock { $0.append(stage) } }) { event in
            events.withLock { $0.append(event.ffi.name) }
        }
        let timing = try #require(recorder.beginTiming())
        await recorder.recordTiming(.timelineWindow, since: timing)?.value
        await recorder.record(.screen(.inbox), ticket: recorder.ticket())?.value
        #expect(stages.withLock { $0 } == [.timelineWindow])
        #expect(events.withLock { $0 } == ["app_screen_viewed"])
    }

    @Test @MainActor func hostTimingRegistryAccepted() async throws {
        let client = try MarmotClient.testClient()
        let config = ProductAnalyticsBuildConfig(
            endpoint: "https://analytics.invalid/api/v0/events", appKey: "A-SH-test",
            operatorLabel: "test", retentionDisclosure: nil, appVersion: "1", osMajorVersion: "27",
            deviceClass: "phone", environment: "staging", isDebug: true
        )
        try client.marmot.setProductAnalyticsRuntimeConfig(config: config.runtimeConfig)
        #expect(try client.marmot.recordHostTiming(
            name: ProductTimingStage.inboxBatch.rawValue, durationMs: 250, outcome: .success
        ) == .ignoredDisabled)
        _ = try client.marmot.setUsageDiagnosticsConsent(enabled: true)
        try await client.marmot.setProductAnalyticsActivity(activity: .foreground)
        for stage in ProductTimingStage.allCases {
            for outcome in [HostPerformanceOutcomeFfi.success, .failure] {
                #expect(try client.marmot.recordHostTiming(name: stage.rawValue, durationMs: 251, outcome: outcome) == .recorded)
            }
        }
        _ = try client.marmot.setUsageDiagnosticsConsent(enabled: false)
        #expect(try client.marmot.recordHostTiming(
            name: ProductTimingStage.inboxBatch.rawValue, durationMs: 250, outcome: .success
        ) == .ignoredDisabled)
        #expect(try client.marmot.usageDiagnosticsStatus().queuedEvents == 0)
        try await client.marmot.shutdownAndClose()
    }

    @Test @MainActor func expandingTimingRegistryRequiresNewConsent() async throws {
        let client = try MarmotClient.testClient()
        var config = ProductAnalyticsBuildConfig(
            endpoint: "https://analytics.invalid/api/v0/events", appKey: "A-SH-test",
            operatorLabel: "test", retentionDisclosure: nil, appVersion: "1", osMajorVersion: "27",
            deviceClass: "phone", environment: "staging", isDebug: true
        ).runtimeConfig
        config.registry = []
        try client.marmot.setProductAnalyticsRuntimeConfig(config: config)
        try await client.marmot.start()
        _ = try client.marmot.setUsageDiagnosticsConsent(enabled: true)
        let oldRegistry = try client.marmot.usageDiagnosticsSettings().registryRevision
        config.registry = ProductTimingStage.registry
        try client.marmot.setProductAnalyticsRuntimeConfig(config: config)
        #expect(try client.marmot.usageDiagnosticsSettings().decision == .acceptanceRequired)
        let liveResult = try client.marmot.recordHostTiming(
            name: ProductTimingStage.inboxBatch.rawValue, durationMs: 250, outcome: .success
        )
        #expect(liveResult == .ignoredDisabled)
        try await client.marmot.shutdownAndClose()

        let upgraded = try MarmotClient(rootPath: client.rootPath, relayUrls: [])
        try upgraded.marmot.setProductAnalyticsRuntimeConfig(config: config)
        try await upgraded.marmot.start()
        #expect(try upgraded.marmot.usageDiagnosticsSettings().decision == .acceptanceRequired)
        let upgradedResult = try upgraded.marmot.recordHostTiming(
            name: ProductTimingStage.inboxBatch.rawValue, durationMs: 250, outcome: .success
        )
        #expect(upgradedResult == .ignoredDisabled)
        _ = try upgraded.marmot.setUsageDiagnosticsConsent(enabled: true)
        #expect(try upgraded.marmot.usageDiagnosticsSettings().registryRevision != oldRegistry)
        try await upgraded.marmot.setProductAnalyticsActivity(activity: .foreground)
        #expect(try upgraded.marmot.recordHostTiming(
            name: ProductTimingStage.inboxBatch.rawValue, durationMs: 250, outcome: .success
        ) == .recorded)
        _ = try upgraded.marmot.setUsageDiagnosticsConsent(enabled: false)
        try await upgraded.marmot.shutdownAndClose()
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

    @Test @MainActor func searchCountsMatchesArrivingDuringRefreshOnce() async {
        let events = Mutex<[ProductEventFfi]>([])
        let recorder = ProductAnalyticsRecorder()
        recorder.replaceSink { event in events.withLock { $0.append(event.ffi) } }
        let search = ConversationSearchModel()
        search.analytics = recorder
        var entries: [ConversationSearchEntry] = []
        search.entriesProvider = { entries }
        search.activate()
        search.query = "match"
        #expect(search.matches.isEmpty)
        entries = [.init(itemId: "late-row", messageIdHex: "late-message", text: "match")]
        search.refreshAfterTimelineChange()
        search.refreshAfterTimelineChange()
        #expect(search.matches.count == 1)
        #expect(events.withLock { $0.isEmpty })
        await search.end()?.value
        #expect(search.end() == nil)
        #expect(events.withLock { $0.map(\.properties) } == [[.init(name: "outcome", value: "success")]])
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
        #expect(try client.marmot.recordHostTiming(
            name: ProductTimingStage.inboxBatch.rawValue, durationMs: 250, outcome: .success
        ) == .ignoredDisabled)
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
        var vocabulary = ProductScreen.allCases.map(ProductEvent.screen)
        vocabulary.append(contentsOf: ProductSettingsSection.allCases.map(ProductEvent.settings))
        vocabulary.append(contentsOf: ProductSearchOutcome.allCases.map(ProductEvent.search))
        vocabulary.append(contentsOf: ProductPermissionOutcome.allCases.map(ProductEvent.permission))
        for action in ProductAttachmentAction.allCases {
            for outcome in [ProductOutcome.success, .failure, .cancelled] {
                vocabulary.append(.attachment(action, outcome))
            }
        }
        for step in ProductOnboardingStep.allCases {
            for path in ProductOnboardingPath.allCases {
                for outcome in ProductOutcome.allCases {
                    vocabulary.append(.onboarding(step, path, outcome))
                }
            }
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
