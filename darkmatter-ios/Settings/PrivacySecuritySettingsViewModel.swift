import Foundation
import MarmotKit

/// Screen store for `PrivacySecuritySettingsView`: owns the telemetry/audit
/// settings projections, the audit-file list, and the save/delete actions, so
/// the view is pure rendering. The developer-mode toggles bind directly to
/// AppState prefs and stay in the view. Methods take `AppState` (no retain).
@MainActor
@Observable
final class PrivacySecuritySettingsViewModel {
    var telemetrySettings: PrivacyTelemetrySettingsProjection?
    var auditSettings: PrivacyAuditSettingsProjection?
    var auditFileRows: [AuditFileRow] = []
    var telemetrySaving = false
    var auditSaving = false
    var auditDeleting = false
    var showDeleteAuditLogsConfirmation = false
    var filesLoading = false
    var errorMessage: String?
    var savedAt: Date?

    var telemetryToggleDisabled: Bool {
        telemetrySaving || telemetrySettings == nil
    }

    func reload(using appState: AppState) async {
        filesLoading = true
        errorMessage = nil
        defer { filesLoading = false }

        do {
            guard let projection = try await appState.privacySecuritySettingsProjection() else { return }
            telemetrySettings = projection.telemetrySettings
            auditSettings = projection.auditSettings
            auditFileRows = projection.auditFileRows
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reloadAuditFiles(using appState: AppState) async {
        filesLoading = true
        errorMessage = nil
        defer { filesLoading = false }

        do {
            guard let rows = try await appState.auditLogFileRows() else { return }
            auditFileRows = rows
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setTelemetryEnabled(_ enabled: Bool, using appState: AppState) async {
        guard let current = telemetrySettings else { return }
        telemetrySaving = true
        errorMessage = nil
        telemetrySettings = current.updatingExportEnabled(enabled)
        defer { telemetrySaving = false }

        do {
            telemetrySettings = PrivacyTelemetrySettingsProjection(
                settings: try await appState.setRelayTelemetryExportEnabled(enabled)
            )
            savedAt = Date()
            Haptics.success()
        } catch {
            telemetrySettings = current
            Haptics.error()
            errorMessage = error.localizedDescription
        }
    }

    func deleteAllAuditLogs(using appState: AppState) async {
        auditDeleting = true
        errorMessage = nil
        defer { auditDeleting = false }

        do {
            try await appState.deleteAllAuditLogFiles()
            savedAt = Date()
            Haptics.success()
            await reloadAuditFiles(using: appState)
        } catch {
            Haptics.error()
            errorMessage = error.localizedDescription
        }
    }

    func setAuditEnabled(_ enabled: Bool, using appState: AppState) async {
        guard let current = auditSettings else { return }
        auditSaving = true
        errorMessage = nil
        auditSettings = PrivacyAuditSettingsProjection(enabled: enabled)
        defer { auditSaving = false }

        do {
            auditSettings = PrivacyAuditSettingsProjection(
                settings: try await appState.setAuditLogEnabled(enabled)
            )
            savedAt = Date()
            Haptics.success()
            await reloadAuditFiles(using: appState)
        } catch {
            auditSettings = current
            Haptics.error()
            errorMessage = error.localizedDescription
        }
    }
}
