import Foundation
import MarmotKit

@MainActor
protocol PrivacySecuritySettingsViewModelDataSource: AnyObject {
    var activeAccountRef: String? { get }

    func privacySecuritySettingsProjection() async throws -> PrivacySecuritySettingsProjection?
    func auditLogFileRows() async throws -> [AuditFileRow]?
    func deleteAllAuditLogFiles() async throws
    func setAuditLogEnabled(_ enabled: Bool) async throws -> AuditLogSettingsFfi
    func present(_ toast: Toast)
}

extension AppState: PrivacySecuritySettingsViewModelDataSource {}

extension PrivacySecuritySettingsViewModelDataSource {
    func present(_ toast: Toast) {}
}

/// Screen store for `PrivacySecuritySettingsView`: owns the telemetry/audit
/// settings projections, the audit-file list, and the save/delete actions, so
/// the view is pure rendering. The developer-mode toggles bind directly to
/// AppState prefs and stay in the view. Methods take an AppState-compatible
/// data source rather than retaining it.
@MainActor
@Observable
final class PrivacySecuritySettingsViewModel {
    var usageEnabled: Bool?
    var auditSettings: PrivacyAuditSettingsProjection?
    var auditFileRows: [AuditFileRow] = [] {
        didSet { storedLogSize = formatStoredLogSize() }
    }
    private(set) var storedLogSize = L10n.string("None")
    var auditSaving = false
    var auditDeleting = false
    var showDeleteAuditLogsConfirmation = false
    var filesLoading = false
    var auditErrorMessage: String?
    var errorMessage: String?
    var savedAt: Date?

    private func formatStoredLogSize() -> String {
        let bytes = auditFileRows.reduce(UInt64(0)) { partial, row in
            let sum = partial.addingReportingOverflow(row.sizeBytes)
            return sum.overflow ? UInt64.max : sum.partialValue
        }
        return bytes == 0 ? L10n.string("None") : ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    var diagnosticsSummary: String {
        switch (usageEnabled, auditSettings?.enabled) {
        case (true, true): L10n.string("On")
        case (true, false): L10n.string("Analytics")
        case (false, true): L10n.string("Logs")
        case (false, false): L10n.string("Off")
        default: L10n.string("Unavailable")
        }
    }

    private var actionGate = AsyncActionGate()
    private var fullReloadRequestedAfterAction = false
    private var auditFilesReloadRequestedAfterAction = false
    private var activeFileLoadIDs: Set<UUID> = []
    /// Account whose privacy state is currently shown. Used to clear
    /// account-scoped state before awaiting a *different* account's projection.
    private var loadedAccountRef: String?

    var auditToggleDisabled: Bool {
        actionGate.isRunning || auditSaving || auditSettings == nil
    }

    var auditDeleteDisabled: Bool {
        actionGate.isRunning || auditDeleting || auditSaving
    }

    private func runAction(
        using dataSource: any PrivacySecuritySettingsViewModelDataSource,
        _ body: () async -> Void
    ) async {
        guard actionGate.tryBegin() else { return }
        await body()
        actionGate.end()
        await drainDeferredReload(using: dataSource)
    }

    private func requestFullReloadAfterAction() {
        fullReloadRequestedAfterAction = true
    }

    private func requestAuditFilesReloadAfterAction() {
        auditFilesReloadRequestedAfterAction = true
    }

    private func drainDeferredReload(using dataSource: any PrivacySecuritySettingsViewModelDataSource) async {
        if fullReloadRequestedAfterAction {
            fullReloadRequestedAfterAction = false
            auditFilesReloadRequestedAfterAction = false
            await reload(using: dataSource)
        } else if auditFilesReloadRequestedAfterAction {
            auditFilesReloadRequestedAfterAction = false
            await reloadAuditFiles(using: dataSource)
        }
    }

    private func deferOrReload(
        _ kind: PrivacySecuritySettingsReloadKind,
        using dataSource: any PrivacySecuritySettingsViewModelDataSource
    ) async {
        if actionGate.isRunning {
            switch kind {
            case .full:
                requestFullReloadAfterAction()
            case .auditFiles:
                requestAuditFilesReloadAfterAction()
            }
        } else {
            switch kind {
            case .full:
                await reload(using: dataSource)
            case .auditFiles:
                await reloadAuditFiles(using: dataSource)
            }
        }
    }

    private func canApplyReload(
        startedAt ticket: Int,
        accountRef: String?,
        using dataSource: any PrivacySecuritySettingsViewModelDataSource
    ) -> Bool {
        actionGate.canApplyReload(startedAt: ticket) && dataSource.activeAccountRef == accountRef
    }

    private func beginFileLoad() -> UUID {
        let id = UUID()
        activeFileLoadIDs.insert(id)
        filesLoading = true
        return id
    }

    private func endFileLoad(_ id: UUID) {
        activeFileLoadIDs.remove(id)
        filesLoading = !activeFileLoadIDs.isEmpty
    }

    func reload(using dataSource: any PrivacySecuritySettingsViewModelDataSource) async {
        guard let reloadTicket = actionGate.reloadTicket() else {
            requestFullReloadAfterAction()
            return
        }
        let accountRef = dataSource.activeAccountRef
        // Switching away from a *previously loaded* account: clear that account's
        // toggles, audit rows, and save banner before awaiting the new
        // projection, so this privacy screen never shows or lets you act on
        // another account's state during the suspended read. Deliberately not on
        // the first load (loadedAccountRef == nil): initial state is already
        // empty, and clearing there would wipe optimistic/seeded state a reload
        // started before a save is expected to preserve.
        if let loadedAccountRef, loadedAccountRef != accountRef {
            usageEnabled = nil
            auditSettings = nil
            auditFileRows = []
            savedAt = nil
        }
        let fileLoadID = beginFileLoad()
        errorMessage = nil
        auditErrorMessage = nil
        defer { endFileLoad(fileLoadID) }

        do {
            guard let projection = try await dataSource.privacySecuritySettingsProjection() else {
                guard canApplyReload(startedAt: reloadTicket, accountRef: accountRef, using: dataSource) else {
                    await deferOrReload(.full, using: dataSource)
                    return
                }
                // No active account / suspended runtime: clear so a previous
                // account's telemetry toggle and audit rows can't linger,
                // matching the sibling settings screens.
                usageEnabled = nil
                auditSettings = nil
                auditFileRows = []
                loadedAccountRef = accountRef
                return
            }
            guard canApplyReload(startedAt: reloadTicket, accountRef: accountRef, using: dataSource) else {
                await deferOrReload(.full, using: dataSource)
                return
            }
            usageEnabled = projection.usageEnabled
            auditSettings = projection.auditSettings
            auditFileRows = projection.auditFileRows
            loadedAccountRef = accountRef
        } catch {
            guard canApplyReload(startedAt: reloadTicket, accountRef: accountRef, using: dataSource) else {
                await deferOrReload(.full, using: dataSource)
                return
            }
            errorMessage = error.localizedDescription
        }
    }

    func reloadAuditFiles(using dataSource: any PrivacySecuritySettingsViewModelDataSource) async {
        guard let reloadTicket = actionGate.reloadTicket() else {
            requestAuditFilesReloadAfterAction()
            return
        }
        let accountRef = dataSource.activeAccountRef
        let fileLoadID = beginFileLoad()
        auditErrorMessage = nil
        defer { endFileLoad(fileLoadID) }

        do {
            guard let rows = try await dataSource.auditLogFileRows() else {
                guard canApplyReload(startedAt: reloadTicket, accountRef: accountRef, using: dataSource) else {
                    await deferOrReload(.auditFiles, using: dataSource)
                    return
                }
                auditFileRows = []
                return
            }
            guard canApplyReload(startedAt: reloadTicket, accountRef: accountRef, using: dataSource) else {
                await deferOrReload(.auditFiles, using: dataSource)
                return
            }
            auditFileRows = rows
        } catch {
            guard canApplyReload(startedAt: reloadTicket, accountRef: accountRef, using: dataSource) else {
                await deferOrReload(.auditFiles, using: dataSource)
                return
            }
            auditErrorMessage = error.localizedDescription
        }
    }

    func deleteAllAuditLogs(using dataSource: any PrivacySecuritySettingsViewModelDataSource) async {
        guard !auditDeleting else { return }
        await runAction(using: dataSource) {
            auditDeleting = true
            auditErrorMessage = nil
            defer { auditDeleting = false }

            do {
                try await dataSource.deleteAllAuditLogFiles()
                // Clear the deleted rows immediately so they don't linger during the
                // follow-up reload.
                auditFileRows = []
                savedAt = Date()
                Haptics.success()
                dataSource.present(.success(L10n.string("Done")))
                await reloadAuditFiles(using: dataSource)
            } catch {
                Haptics.error()
                dataSource.present(UserFacingError.toast(
                    title: L10n.string("Delete failed"),
                    error: error
                ))
            }
        }
    }

    func setAuditEnabled(_ enabled: Bool, using dataSource: any PrivacySecuritySettingsViewModelDataSource) async {
        guard !auditSaving else { return }
        guard let current = auditSettings else { return }
        await runAction(using: dataSource) {
            auditSaving = true
            auditErrorMessage = nil
            auditSettings = current.updatingEnabled(enabled)
            defer { auditSaving = false }

            do {
                auditSettings = PrivacyAuditSettingsProjection(
                    settings: try await dataSource.setAuditLogEnabled(enabled)
                )
                savedAt = Date()
                Haptics.success()
                dataSource.present(.success(L10n.string("Done")))
                await reloadAuditFiles(using: dataSource)
            } catch {
                auditSettings = current
                auditErrorMessage = L10n.string("Couldn’t save diagnostic logging settings. Try again.")
                Haptics.error()
                dataSource.present(UserFacingError.toast(
                    title: L10n.string("Save failed"),
                    error: error
                ))
            }
        }
    }

}

private enum PrivacySecuritySettingsReloadKind {
    case full
    case auditFiles
}
