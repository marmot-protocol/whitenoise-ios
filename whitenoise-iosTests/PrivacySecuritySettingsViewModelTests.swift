import Foundation
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

@MainActor
private final class MockPrivacyDataSource: PrivacySecuritySettingsViewModelDataSource {
    var activeAccountRef: String?
    var projection: PrivacySecuritySettingsProjection?
    var auditRows: [AuditFileRow]?
    /// Lists returned by successive reads (nil: unreadable) before falling back to `auditRows`.
    var queuedAuditRows: [[AuditFileRow]?] = []
    private(set) var auditRowsReads = 0
    var suspendProjection = false
    var suspendAuditRows = false
    private(set) var auditSettingsRequests: [AuditLogSettingsFfi] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var auditGate: CheckedContinuation<Void, Never>?
    private var projectionStarted = false
    private var auditRowsStarted = false
    private var projectionStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var auditRowsStartedWaiters: [CheckedContinuation<Void, Never>] = []

    func privacySecuritySettingsProjection() async throws -> PrivacySecuritySettingsProjection? {
        projectionStarted = true
        projectionStartedWaiters.forEach { $0.resume() }
        projectionStartedWaiters = []
        if suspendProjection {
            await withCheckedContinuation { gate = $0 }
        }
        return projection
    }

    func releaseSuspendedProjection() {
        gate?.resume()
        gate = nil
    }

    func auditLogFileRows() async throws -> [AuditFileRow]? {
        auditRowsReads += 1
        if !queuedAuditRows.isEmpty { auditRows = queuedAuditRows.removeFirst() }
        auditRowsStarted = true
        auditRowsStartedWaiters.forEach { $0.resume() }
        auditRowsStartedWaiters = []
        if suspendAuditRows {
            await withCheckedContinuation { auditGate = $0 }
        }
        return auditRows
    }

    func waitUntilProjectionStarted() async {
        guard !projectionStarted else { return }
        await withCheckedContinuation { projectionStartedWaiters.append($0) }
    }

    func waitUntilAuditRowsStarted() async {
        guard !auditRowsStarted else { return }
        await withCheckedContinuation { auditRowsStartedWaiters.append($0) }
    }

    func releaseSuspendedAuditRows() {
        auditGate?.resume()
        auditGate = nil
    }
    func deleteAllAuditLogFiles() async throws { throw CancellationError() }
    func setAuditLogEnabled(_ enabled: Bool) async throws -> AuditLogSettingsFfi {
        let settings = AuditLogSettingsFfi(enabled: enabled)
        auditSettingsRequests.append(settings)
        return settings
    }
}

@MainActor
struct PrivacySecuritySettingsViewModelTests {
    private func logRow(_ name: String, modifiedAtMs: UInt64) -> AuditFileRow {
        AuditFileRow(fileName: name, detailText: name, path: "/logs/\(name)", sizeBytes: 1_024, modifiedAtMs: modifiedAtMs)
    }

    @Test func aShorterRetentionRereadsLogsUntilTheSweepHasRemovedTheOldOnes() async {
        let cutoff: UInt64 = 1_000_000
        let old = logRow("old.jsonl", modifiedAtMs: cutoff - 1)
        let recent = logRow("recent.jsonl", modifiedAtMs: cutoff + 1)
        let source = MockPrivacyDataSource()
        source.queuedAuditRows = [[old, recent], [old, recent], [recent]]
        let model = PrivacySecuritySettingsViewModel()
        var sleeps = 0

        await model.reloadAuditFilesAfterRetentionChange(cutoffMs: cutoff, using: source) { _ in sleeps += 1 }

        #expect(model.auditFileRows == [recent])
        #expect(source.auditRowsReads == 3)
        #expect(sleeps == 2)
    }

    @Test func anUnreadableListDuringTheWaitKeepsTheRowsAndKeepsWaiting() async {
        let cutoff: UInt64 = 1_000_000
        let old = logRow("old.jsonl", modifiedAtMs: cutoff - 1)
        let recent = logRow("recent.jsonl", modifiedAtMs: cutoff + 1)
        let source = MockPrivacyDataSource()
        source.auditRows = [old, recent]
        let model = PrivacySecuritySettingsViewModel()
        await model.reloadAuditFiles(using: source)
        source.queuedAuditRows = [nil, [old, recent], [recent]]
        var rowsDuringWait: [[AuditFileRow]] = []
        var showedLoading = false

        await model.reloadAuditFilesAfterRetentionChange(cutoffMs: cutoff, using: source) { _ in
            rowsDuringWait.append(model.auditFileRows)
            showedLoading = showedLoading || model.filesLoading
        }

        #expect(rowsDuringWait.first == [old, recent])
        #expect(model.auditFileRows == [recent])
        #expect(!showedLoading)
    }

    @Test func aSweepThatNeverLandsStopsAfterABoundedNumberOfReads() async {
        let cutoff: UInt64 = 1_000_000
        let source = MockPrivacyDataSource()
        source.auditRows = [logRow("old.jsonl", modifiedAtMs: cutoff - 1)]
        let model = PrivacySecuritySettingsViewModel()

        await model.reloadAuditFilesAfterRetentionChange(cutoffMs: cutoff, using: source) { _ in }

        #expect(source.auditRowsReads == PrivacySecuritySettingsViewModel.retentionSweepReads)
    }

    @Test func enablingAuditLoggingUpdatesTheEngineSetting() async {
        let model = PrivacySecuritySettingsViewModel()
        let source = MockPrivacyDataSource()
        model.auditSettings = PrivacyAuditSettingsProjection(enabled: false)

        await model.setAuditEnabled(true, using: source)

        #expect(source.auditSettingsRequests == [
            AuditLogSettingsFfi(enabled: true)
        ])
        #expect(model.auditSettings?.enabled == true)
    }

    @Test func overlappingFileLoadsKeepSpinnerUntilBothComplete() async {
        let model = PrivacySecuritySettingsViewModel()
        let source = MockPrivacyDataSource()
        source.activeAccountRef = "account-a"
        source.suspendProjection = true
        source.suspendAuditRows = true

        let fullReload = Task { @MainActor in await model.reload(using: source) }
        await source.waitUntilProjectionStarted()
        let fileReload = Task { @MainActor in await model.reloadAuditFiles(using: source) }
        await source.waitUntilAuditRowsStarted()
        #expect(model.filesLoading)

        source.releaseSuspendedAuditRows()
        await fileReload.value
        #expect(model.filesLoading)

        source.releaseSuspendedProjection()
        await fullReload.value
        #expect(!model.filesLoading)
    }

    /// Switching accounts must clear the previous account's toggles, audit rows,
    /// and save banner *before* the new account's projection read resolves, so a
    /// suspended read can't leave another account's privacy state on screen.
    @Test func accountSwitchClearsPreviousStateBeforeSuspendedProjectionResolves() async {
        let model = PrivacySecuritySettingsViewModel()
        let source = MockPrivacyDataSource()
        source.activeAccountRef = "account-a"
        source.projection = PrivacySecuritySettingsProjection(
            usageEnabled: true,
            auditSettings: PrivacyAuditSettingsProjection(enabled: true),
            auditFileRows: [AuditFileRow(fileName: "a.log", detailText: "1 KB - account-a", path: "/a.log")]
        )

        await model.reload(using: source)
        #expect(model.usageEnabled != nil)
        #expect(model.auditSettings != nil)
        #expect(!model.auditFileRows.isEmpty)
        model.savedAt = Date()

        // Switch to account B with a suspended (hanging) projection read.
        source.activeAccountRef = "account-b"
        source.projection = nil
        source.suspendProjection = true
        let reloadTask = Task { await model.reload(using: source) }
        await Task.yield()
        await Task.yield()

        // The previous account's state is already cleared while the read hangs.
        #expect(model.usageEnabled == nil)
        #expect(model.auditSettings == nil)
        #expect(model.auditFileRows.isEmpty)
        #expect(model.savedAt == nil)

        source.releaseSuspendedProjection()
        await reloadTask.value
    }

    /// A refresh of the same account must not blank the screen: the clear only
    /// fires on an account change.
    @Test func sameAccountReloadKeepsState() async {
        let model = PrivacySecuritySettingsViewModel()
        let source = MockPrivacyDataSource()
        source.activeAccountRef = "account-a"
        source.projection = PrivacySecuritySettingsProjection(
            usageEnabled: true,
            auditSettings: PrivacyAuditSettingsProjection(enabled: false),
            auditFileRows: [AuditFileRow(fileName: "a.log", detailText: "1 KB - account-a", path: "/a.log")]
        )

        await model.reload(using: source)
        await model.reload(using: source)

        #expect(model.usageEnabled != nil)
        #expect(!model.auditFileRows.isEmpty)
    }
}
