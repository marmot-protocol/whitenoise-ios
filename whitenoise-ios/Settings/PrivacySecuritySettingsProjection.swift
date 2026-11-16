import Foundation
import MarmotKit

nonisolated struct PrivacySecuritySettingsProjection: Equatable, Sendable {
    var usageEnabled: Bool?
    var auditSettings: PrivacyAuditSettingsProjection?
    var auditFileRows: [AuditFileRow]

    static let empty = PrivacySecuritySettingsProjection(
        usageEnabled: nil,
        auditSettings: nil,
        auditFileRows: []
    )
}

nonisolated struct PrivacyAuditSettingsProjection: Equatable, Sendable {
    var enabled: Bool

    init(settings: AuditLogSettingsFfi) {
        self.enabled = settings.enabled
    }

    init(enabled: Bool) {
        self.enabled = enabled
    }

    func updatingEnabled(_ enabled: Bool) -> Self {
        Self(enabled: enabled)
    }
}

nonisolated struct AuditFileRow: Identifiable, Equatable, Sendable {
    var id: String { path }
    let fileName: String
    let detailText: String
    let path: String
    var sizeBytes: UInt64 = 0
    var modifiedAtMs: UInt64?
}

nonisolated enum AuditFileRowProjection {
    /// Newest capture first; undated files last; path breaks ties so order is stable.
    static func rows(
        from files: [AuditLogFileFfi],
        locale: Locale = MarkdownTimestampFormatter.currentLocale,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> [AuditFileRow] {
        files.sorted { left, right in
            switch (left.modifiedAtMs, right.modifiedAtMs) {
            case let (leftTime?, rightTime?) where leftTime != rightTime: leftTime > rightTime
            case (.some, nil): true
            case (nil, .some): false
            default: left.path < right.path
            }
        }
        .map { file in
            AuditFileRow(
                fileName: file.fileName,
                detailText: details(for: file, locale: locale, timeZone: timeZone),
                path: file.path,
                sizeBytes: file.sizeBytes,
                modifiedAtMs: file.modifiedAtMs
            )
        }
    }

    /// Size and capture time, short enough for one caption line.
    private static func details(for file: AuditLogFileFfi, locale: Locale, timeZone: TimeZone) -> String {
        let size = byteCount(file.sizeBytes)
        guard let modifiedAtMs = file.modifiedAtMs else { return size }
        return "\(size) - \(modifiedText(Date(timeIntervalSince1970: TimeInterval(modifiedAtMs) / 1_000), locale: locale, timeZone: timeZone))"
    }

    /// "14 November 2026, 10:50": the combined date-time style would add "at".
    static func modifiedText(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        var dateStyle = Date.FormatStyle.dateTime.day().month(.wide).year().locale(locale)
        dateStyle.timeZone = timeZone
        var timeStyle = Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)
        timeStyle.timeZone = timeZone
        return L10n.formatted("%@, %@", arguments: [date.formatted(dateStyle), date.formatted(timeStyle)], locale: locale)
    }

    private static func byteCount(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}
