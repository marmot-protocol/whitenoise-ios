import Foundation
import MarmotKit

extension AppState: DeviceDiagnosticsDataSource {
    func deviceDiagnosticsSnapshot() async throws -> DeviceDiagnosticsSnapshot? {
        guard phaseOwnsLiveRuntime, canUseRuntimeForLocalForegroundWork, let client else { return nil }
        let snapshot = try await client.deviceDiagnosticsSnapshot()
        guard self.client === client, canUseRuntimeForLocalForegroundWork else { throw CancellationError() }
        return snapshot
    }

    func saveUsageDiagnosticsConsent(_ enabled: Bool) async throws -> DeviceDiagnosticsSnapshot {
        let lease = try runtimeLifecycle.beginForegroundRuntimeMutation()
        defer { runtimeLifecycle.endForegroundRuntimeMutation(lease) }
        invalidateProductAnalytics()
        let revision = productContextRevision
        productConsentMutationInProgress = true
        defer { productConsentMutationInProgress = false }
        do {
            _ = try await lease.client.setUsageDiagnosticsConsent(enabled)
            let snapshot = try await lease.client.deviceDiagnosticsSnapshot()
            await activateProductAnalytics(using: lease.client, snapshot: snapshot, revision: revision)
            return snapshot
        } catch {
            productAnalytics.replaceSink(nil)
            throw error
        }
    }

    func saveDiagnosticLogging(_ enabled: Bool) async throws -> DeviceDiagnosticsSnapshot {
        let lease = try runtimeLifecycle.beginForegroundRuntimeMutation()
        defer { runtimeLifecycle.endForegroundRuntimeMutation(lease) }
        _ = try await lease.client.marmot.setAuditLogSettings(settings: AuditLogSettingsFfi(enabled: enabled))
        return try await lease.client.deviceDiagnosticsSnapshot()
    }

    func refreshProductAnalytics() async {
        guard !productConsentMutationInProgress, let client, canUseRuntimeForLocalForegroundWork else { return }
        let revision = productContextRevision
        do {
            let snapshot = try await client.deviceDiagnosticsSnapshot()
            await activateProductAnalytics(using: client, snapshot: snapshot, revision: revision)
        } catch {
            if productContextRevision == revision { productAnalytics.replaceSink(nil) }
        }
        guard productContextRevision == revision, self.client === client else { return }
        await diagnosticsConsent.reload(using: self)
    }

    private func activateProductAnalytics(using activeClient: MarmotClient, snapshot: DeviceDiagnosticsSnapshot, revision: UUID) async {
        guard productContextRevision == revision, client === activeClient, canUseRuntimeForLocalForegroundWork else { return }
        let activity = pendingProductActivity
        pendingProductActivity = .foreground
        try? await activeClient.marmot.setProductAnalyticsActivity(activity: activity)
        guard productContextRevision == revision, client === activeClient, canUseRuntimeForLocalForegroundWork else { return }
        if snapshot.settings.decision == .granted {
            productAnalytics.activateSink(performance: { [activeClient] operation, milliseconds in
                activeClient.recordHostPerformance(operation: operation, durationMs: milliseconds, outcome: .success)
            }) { [activeClient] event in
                switch event {
                case .timing(let stage, let milliseconds, let outcome):
                    _ = try activeClient.marmot.recordHostTiming(
                        name: stage.rawValue, durationMs: milliseconds, outcome: outcome
                    )
                default:
                    _ = try activeClient.marmot.recordProductEvent(event: event.ffi)
                }
            }
        } else {
            productAnalytics.replaceSink(nil)
        }
    }

    func beginProductOnboarding(_ path: ProductOnboardingPath) {
        productOnboardingPath = path
        productOnboardingTicket = productAnalytics.ticket()
        productAnalytics.record(.onboarding(.start, path, .success), ticket: productOnboardingTicket)
    }

    func cancelProductOnboardingIfAbandoned() {
        guard pendingAccountSetup == nil, let path = productOnboardingPath else { return }
        productAnalytics.record(.onboarding(.complete, path, .cancelled), ticket: productOnboardingTicket)
        productOnboardingPath = nil
        productOnboardingTicket = nil
    }

    func invalidateProductAnalytics() {
        productContextRevision = UUID()
        productAnalytics.replaceSink(nil)
    }

    func productActivation(_ activity: ProductAnalyticsActivityFfi) {
        pendingProductActivity = activity
        guard canUseRuntimeForLocalForegroundWork else { return }
        Task { await refreshProductAnalytics() }
    }

    func productAccountChanged() {
        invalidateProductAnalytics()
        let revision = productContextRevision
        guard let client, canUseRuntimeForLocalForegroundWork else { return }
        Task {
            try? await client.marmot.setProductAnalyticsActivity(activity: .accountChanged)
            guard self.client === client, productContextRevision == revision else { return }
            await refreshProductAnalytics()
        }
    }
}
