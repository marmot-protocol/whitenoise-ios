import Foundation
import MarmotKit

nonisolated struct DeviceDiagnosticsSnapshot: Sendable {
    let settings: UsageDiagnosticsSettingsFfi
    let status: UsageDiagnosticsStatusFfi
    let auditEnabled: Bool

    let exporterSummary: String

    init(settings: UsageDiagnosticsSettingsFfi, status: UsageDiagnosticsStatusFfi, auditEnabled: Bool) {
        self.settings = settings
        self.status = status
        self.auditEnabled = auditEnabled
        self.exporterSummary = L10n.formatted("Usage: %@. Diagnostics: %@.", Self.label(status.productAnalytics), Self.label(status.telemetry))
    }

    static func label(_ status: DiagnosticsExporterStatusFfi) -> String {
        switch status {
        case .disabled: L10n.string("Off")
        case .consentRequired: L10n.string("Permission needed")
        case .unconfigured: L10n.string("Not configured")
        case .unsupportedBuild: L10n.string("Unavailable in this build")
        case .ready: L10n.string("Ready to share")
        case .configurationRejected: L10n.string("Configuration rejected")
        }
    }
}

@MainActor
protocol DeviceDiagnosticsDataSource: AnyObject {
    func deviceDiagnosticsSnapshot() async throws -> DeviceDiagnosticsSnapshot?
    func saveUsageDiagnosticsConsent(_ enabled: Bool) async throws -> DeviceDiagnosticsSnapshot
    func saveDiagnosticLogging(_ enabled: Bool) async throws -> DeviceDiagnosticsSnapshot
}

@MainActor @Observable
final class DeviceDiagnosticsConsent {
    private(set) var snapshot: DeviceDiagnosticsSnapshot?
    private(set) var loading = false
    private(set) var saving = false
    private(set) var errorMessage: String?
    var onboardingVisible = false
    private var generation = UUID()

    // Old prompt flags are deliberately ignored. MDK owns the only receipt.
    init(defaults: UserDefaults = .standard) {}

    var pending: Bool { snapshot?.settings.decision == .acceptanceRequired }
    var usageEnabled: Bool { snapshot?.settings.decision == .granted }
    var auditEnabled: Bool { snapshot?.auditEnabled ?? false }
    var available: Bool { snapshot != nil && !loading && !saving }
    var initialDecisionResolved: Bool { snapshot != nil && !pending }

    var explanation: String? {
        guard let settings = snapshot?.settings, pending else { return nil }
        if settings.previouslyEnabled && settings.policyRevision.isEmpty {
            return L10n.string("You previously shared reliability metrics. Sharing now also includes feature usage, so we need your permission again.")
        }
        if !settings.policyRevision.isEmpty {
            return L10n.string("The scope of usage and diagnostics has changed. Review the updated information before sharing again.")
        }
        return nil
    }

    func canPresent(chatsVisible: Bool, anotherSheetVisible: Bool, runtimeReady: Bool, chatNavigationPending: Bool = false) -> Bool {
        pending && chatsVisible && !chatNavigationPending && !onboardingVisible && !anotherSheetVisible && runtimeReady
    }

    func reload(using source: any DeviceDiagnosticsDataSource) async {
        guard !saving else { return }
        let ticket = UUID()
        generation = ticket
        loading = true
        defer { if generation == ticket { loading = false } }
        do {
            let result = try await source.deviceDiagnosticsSnapshot()
            guard generation == ticket, !Task.isCancelled else { return }
            snapshot = result
            errorMessage = nil
        } catch {
            guard generation == ticket else { return }
            snapshot = nil
            errorMessage = L10n.string("Couldn’t load sharing settings. Try again.")
        }
    }

    @discardableResult
    func setUsage(_ enabled: Bool, using source: any DeviceDiagnosticsDataSource) async -> Bool {
        await save(using: source) { try await source.saveUsageDiagnosticsConsent(enabled) }
    }

    @discardableResult
    func setAudit(_ enabled: Bool, using source: any DeviceDiagnosticsDataSource) async -> Bool {
        await save(using: source) { try await source.saveDiagnosticLogging(enabled) }
    }

    func finishPrompt(using source: any DeviceDiagnosticsDataSource) async -> Bool {
        guard available, errorMessage == nil else { return false }
        if pending { return await setUsage(false, using: source) }
        return true
    }

    private func save(
        using source: any DeviceDiagnosticsDataSource,
        operation: () async throws -> DeviceDiagnosticsSnapshot
    ) async -> Bool {
        guard available else { return false }
        generation = UUID()
        let ticket = generation
        saving = true
        errorMessage = nil
        defer { if generation == ticket { saving = false } }
        do {
            let result = try await operation()
            guard generation == ticket else { return false }
            snapshot = result
            return true
        } catch {
            guard generation == ticket else { return false }
            // A failed consent save disables export in this process. The old
            // receipt must not be rendered as a successfully saved new choice.
            snapshot = nil
            errorMessage = L10n.string("Couldn’t save sharing settings. Your change was not confirmed. Try again.")
            return false
        }
    }

    func reset() {
        generation = UUID()
        snapshot = nil
        loading = false
        saving = false
        errorMessage = nil
    }
}
