import Foundation
import MarmotKit

nonisolated struct PrivacySecuritySettingsProjection: Equatable, Sendable {
    var telemetrySettings: PrivacyTelemetrySettingsProjection?
    var auditSettings: PrivacyAuditSettingsProjection?
    var auditFileRows: [AuditFileRow]

    static let empty = PrivacySecuritySettingsProjection(
        telemetrySettings: nil,
        auditSettings: nil,
        auditFileRows: []
    )

    init(
        telemetrySettings: RelayTelemetrySettingsFfi,
        auditSettings: AuditLogSettingsFfi,
        auditFiles: [AuditLogFileFfi]
    ) {
        self.telemetrySettings = PrivacyTelemetrySettingsProjection(settings: telemetrySettings)
        self.auditSettings = PrivacyAuditSettingsProjection(settings: auditSettings)
        self.auditFileRows = AuditFileRowProjection.rows(from: auditFiles)
    }

    init(
        telemetrySettings: PrivacyTelemetrySettingsProjection?,
        auditSettings: PrivacyAuditSettingsProjection?,
        auditFileRows: [AuditFileRow]
    ) {
        self.telemetrySettings = telemetrySettings
        self.auditSettings = auditSettings
        self.auditFileRows = auditFileRows
    }
}

nonisolated struct PrivacyTelemetrySettingsProjection: Equatable, Sendable {
    var exportEnabled: Bool
    var exportIntervalSeconds: UInt64

    init(settings: RelayTelemetrySettingsFfi) {
        self.exportEnabled = settings.exportEnabled
        self.exportIntervalSeconds = settings.exportIntervalSeconds
    }

    init(exportEnabled: Bool, exportIntervalSeconds: UInt64) {
        self.exportEnabled = exportEnabled
        self.exportIntervalSeconds = exportIntervalSeconds
    }

    func updatingExportEnabled(_ enabled: Bool) -> Self {
        Self(exportEnabled: enabled, exportIntervalSeconds: exportIntervalSeconds)
    }
}

nonisolated struct PrivacyAuditSettingsProjection: Equatable, Sendable {
    var enabled: Bool

    init(settings: AuditLogSettingsFfi) {
        self.enabled = settings.enabled
    }

    init(enabled: Bool) {
        self.enabled = enabled
    }
}

nonisolated struct AuditFileRow: Identifiable, Equatable, Sendable {
    var id: String { path }
    let fileName: String
    let detailText: String
    let path: String
}

nonisolated enum AuditFileRowProjection {
    static func rows(from files: [AuditLogFileFfi]) -> [AuditFileRow] {
        files.map(row)
    }

    private static func row(from file: AuditLogFileFfi) -> AuditFileRow {
        AuditFileRow(
            fileName: file.fileName,
            detailText: details(for: file),
            path: file.path
        )
    }

    private static func details(for file: AuditLogFileFfi) -> String {
        var parts = [byteCount(file.sizeBytes)]
        if let modifiedAtMs = file.modifiedAtMs {
            let date = Date(timeIntervalSince1970: TimeInterval(modifiedAtMs) / 1_000)
            parts.append(date.formatted(date: .abbreviated, time: .shortened))
        }
        parts.append(shortAccountRef(file.accountRef))
        return parts.joined(separator: " - ")
    }

    private static func byteCount(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    private static func shortAccountRef(_ ref: String) -> String {
        let capped = String(ref.prefix(64))
        guard capped.count > 14 else { return capped }
        return "\(capped.prefix(8))...\(capped.suffix(6))"
    }
}
