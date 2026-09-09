import Foundation
import MarmotKit
import SwiftUI
import Synchronization

nonisolated enum ProductScreen: String, CaseIterable, Sendable {
    case onboarding, inbox, conversation, directory, compose, groupDetails = "group_details", settings, diagnostics
}
nonisolated enum ProductOutcome: String, CaseIterable, Sendable { case success, failure, pending, cancelled }
nonisolated enum ProductOnboardingPath: String, CaseIterable, Sendable { case create, `import` }
nonisolated enum ProductOnboardingStep: String, CaseIterable, Sendable {
    case start, identitySelection = "identity_selection", localReady = "local_ready", networkReady = "network_ready", complete
}
nonisolated enum ProductAttachmentAction: String, CaseIterable, Sendable { case picker, open, save }
nonisolated enum ProductSearchOutcome: String, CaseIterable, Sendable { case success, empty, failure, cancelled }
nonisolated enum ProductSettingsSection: String, CaseIterable, Sendable { case appearance, notifications, privacy, account, storage, diagnostics }
nonisolated enum ProductPermissionOutcome: String, CaseIterable, Sendable { case granted, denied, restricted, provisional }
nonisolated enum ProductTimingStage: String, CaseIterable, Sendable {
    case timelineWindow = "app_timeline_window"
    case timelineTail = "app_timeline_tail"
    case timelineDelta = "app_timeline_delta"
    case timelineRebuild = "app_timeline_rebuild"
    case timelineProfiles = "app_timeline_profiles"
    case outgoingProjection = "app_outgoing_projection"
    case outgoingConfirmation = "app_outgoing_confirmation"
    case markdownRebuild = "app_markdown_rebuild"
    case mediaRebuild = "app_media_rebuild"
    case inboxSnapshot = "app_inbox_snapshot"
    case inboxBatch = "app_inbox_batch"
    case inboxRefresh = "app_inbox_refresh"
    case inboxPublish = "app_inbox_publish"
    case composerMarkdown = "app_composer_markdown"
    case cameraPrepare = "app_camera_prepare"
    case libraryPrepare = "app_library_prepare"

    static var registry: [ProductEventSchemaFfi] {
        allCases.map { stage in
            ProductEventSchemaFfi(name: stage.rawValue, mode: .aggregate, properties: [
                ProductPropertySchemaFfi(name: "elapsed", kind: .durationBucket, choices: []),
                ProductPropertySchemaFfi(name: "outcome", kind: .enum, choices: ["success", "failure"])
            ])
        }
    }
}

nonisolated enum ProductEvent: Sendable {
    case screen(ProductScreen)
    case timing(ProductTimingStage, milliseconds: UInt64, outcome: HostPerformanceOutcomeFfi)
    case onboarding(ProductOnboardingStep, ProductOnboardingPath, ProductOutcome)
    case ready(success: Bool, milliseconds: UInt64)
    case compose(cancelled: Bool)
    case search(ProductSearchOutcome)
    case attachment(ProductAttachmentAction, ProductOutcome)
    case settings(ProductSettingsSection)
    case permission(ProductPermissionOutcome)

    var ffi: ProductEventFfi {
        let name: String
        let properties: [String: String]
        switch self {
        case .timing(let stage, let milliseconds, let outcome):
            name = stage.rawValue
            properties = ["elapsed": Self.durationBucket(milliseconds), "outcome": outcome == .success ? "success" : "failure"]
        case .screen(let screen):
            name = "app_screen_viewed"; properties = ["screen": screen.rawValue]
        case .onboarding(let step, let path, let outcome):
            name = "mdk_onboarding_step"
            properties = ["step": step.rawValue, "path": path.rawValue, "outcome": outcome.rawValue]
        case .ready(let success, let milliseconds):
            name = "mdk_runtime_ready"
            properties = ["outcome": success ? "success" : "failure", "duration_bucket": Self.durationBucket(milliseconds)]
        case .compose(let cancelled):
            name = "app_compose"; properties = ["action": cancelled ? "cancel" : "open"]
        case .search(let outcome):
            name = "app_message_search"; properties = ["outcome": outcome.rawValue]
        case .attachment(let action, let outcome):
            name = "app_attachment"; properties = ["action": action.rawValue, "outcome": outcome.rawValue]
        case .settings(let section):
            name = "app_settings"; properties = ["section": section.rawValue]
        case .permission(let outcome):
            name = "app_notification_permission"; properties = ["outcome": outcome.rawValue]
        }
        return ProductEventFfi(name: name, properties: properties.sorted { $0.key < $1.key }.map {
            ProductEventPropertyFfi(name: $0.key, value: $0.value)
        })
    }

    static func durationBucket(_ milliseconds: UInt64) -> String {
        let bounds: [UInt64] = [10, 25, 50, 100, 250, 500, 1_000, 2_000, 5_000, 10_000, 30_000, 60_000, 300_000, 900_000, 3_600_000]
        let names = ["le_10ms", "le_25ms", "le_50ms", "le_100ms", "le_250ms", "le_500ms", "le_1s", "le_2s", "le_5s", "le_10s", "le_30s", "le_1m", "le_5m", "le_15m", "le_60m", "gt_60m"]
        return names[bounds.firstIndex(where: { milliseconds <= $0 }) ?? bounds.count]
    }
}

/// Tickets admit only work begun under this runtime/context's existing consent.
nonisolated final class ProductAnalyticsRecorder: Sendable {
    struct Ticket: Equatable, Sendable { fileprivate let generation: UUID }
    struct Timing: Sendable {
        fileprivate let ticket: Ticket
        fileprivate let startedAt: ContinuousClock.Instant
    }
    private struct State: Sendable {
        var generation = UUID()
        var sink: (@Sendable (ProductEvent) throws -> Void)?
        var performanceSink: (@Sendable (HostPerformanceOperationFfi, UInt64) -> Void)?
        var pending = 0
    }
    private let state = Mutex(State())

    func replaceSink(_ sink: (@Sendable (ProductEvent) throws -> Void)?) {
        state.withLock { $0.generation = UUID(); $0.sink = sink; $0.performanceSink = nil }
    }

    func activateSink(
        performance: (@Sendable (HostPerformanceOperationFfi, UInt64) -> Void)? = nil,
        _ sink: @escaping @Sendable (ProductEvent) throws -> Void
    ) {
        state.withLock { $0.sink = sink; $0.performanceSink = performance }
    }

    func ticket() -> Ticket? {
        state.withLock { $0.sink == nil ? nil : Ticket(generation: $0.generation) }
    }

    @discardableResult
    func record(_ event: ProductEvent, ticket: Ticket?) -> Task<Void, Never>? {
        enqueue(ticket: ticket) { try $0.sink?(event) }
    }

    @discardableResult
    func recordPerformance(_ operation: HostPerformanceOperationFfi, milliseconds: UInt64, ticket: Ticket?) -> Task<Void, Never>? {
        enqueue(ticket: ticket) { $0.performanceSink?(operation, milliseconds) }
    }

    private func enqueue(ticket: Ticket?, deliver: @escaping @Sendable (State) throws -> Void) -> Task<Void, Never>? {
        guard let ticket else { return nil }
        let admitted = state.withLock { state in
            guard state.generation == ticket.generation, state.sink != nil, state.pending < 64 else { return false }
            state.pending += 1
            return true
        }
        guard admitted else { return nil }
        return Task.detached(priority: .utility) { [self] in
            state.withLock { state in
                defer { state.pending -= 1 }
                guard state.generation == ticket.generation else { return }
                // The Rust recorder is memory-only. Hold the gate through this
                // call so revocation cannot overtake an admitted observation.
                // MainActor ticket reads share this lock; sinks must never do I/O.
                do {
                    try deliver(state)
                } catch {
                    state.sink = nil
                    state.performanceSink = nil
                    state.generation = UUID()
                }
            }
        }
    }

    func beginTiming(at now: ContinuousClock.Instant = .now) -> Timing? {
        guard let ticket = ticket() else { return nil }
        return Timing(ticket: ticket, startedAt: now)
    }

    @discardableResult
    func recordTiming(
        _ stage: ProductTimingStage,
        since timing: Timing?,
        outcome: HostPerformanceOutcomeFfi = .success,
        at now: ContinuousClock.Instant = .now
    ) -> Task<Void, Never>? {
        guard let timing else { return nil }
        let elapsed = timing.startedAt.duration(to: max(timing.startedAt, now)).components
        let seconds = UInt64(elapsed.seconds)
        let fractionalMilliseconds = UInt64(elapsed.attoseconds) / 1_000_000_000_000_000
        let (wholeMilliseconds, overflow) = seconds.multipliedReportingOverflow(by: 1_000)
        let (milliseconds, additionOverflow) = wholeMilliseconds.addingReportingOverflow(fractionalMilliseconds)
        return record(.timing(stage, milliseconds: overflow || additionOverflow ? .max : milliseconds, outcome: outcome),
                      ticket: timing.ticket)
    }

    func record(_ event: ProductEvent) {
        record(event, ticket: ticket())
    }
}

nonisolated struct ProductComposeObservation {
    private var started = false
    private var finished = false
    private var ticket: ProductAnalyticsRecorder.Ticket?

    @discardableResult
    mutating func begin(using recorder: ProductAnalyticsRecorder) -> Task<Void, Never>? {
        guard !started else { return nil }
        started = true
        ticket = recorder.ticket()
        return recorder.record(.compose(cancelled: false), ticket: ticket)
    }

    mutating func complete() { finished = true }

    @discardableResult
    mutating func end(using recorder: ProductAnalyticsRecorder, temporarilyCovered: Bool) -> Task<Void, Never>? {
        guard started, !finished, !temporarilyCovered else { return nil }
        finished = true
        return recorder.record(.compose(cancelled: true), ticket: ticket)
    }
}

private struct ProductScreenObservation: ViewModifier {
    @Environment(AppState.self) private var appState
    let screen: ProductScreen
    let section: ProductSettingsSection?
    func body(content: Content) -> some View {
        content.onAppear {
            appState.productAnalytics.record(.screen(screen))
            if let section { appState.productAnalytics.record(.settings(section)) }
        }
    }
}
extension View {
    func productScreen(_ screen: ProductScreen, section: ProductSettingsSection? = nil) -> some View {
        modifier(ProductScreenObservation(screen: screen, section: section))
    }
}
