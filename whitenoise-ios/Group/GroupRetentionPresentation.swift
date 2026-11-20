import Foundation

/// Pure decisions behind the disappearing-messages timer editor: the preset
/// table, custom-duration parsing/bounds, and whether a change needs the
/// retroactive-prune confirmation.
nonisolated enum GroupRetentionPresentation {

    /// Off plus the standard timer presets, in display order. `0` disables.
    static let presetSeconds: [UInt64] = [
        0,
        30,
        5 * 60,
        60 * 60,
        8 * 60 * 60,
        24 * 60 * 60,
        7 * 24 * 60 * 60,
        30 * 24 * 60 * 60,
    ]

    static let minCustomSeconds: UInt64 = 30
    static let maxCustomSeconds: UInt64 = 365 * 24 * 60 * 60

    /// The engine prunes retroactively: enabling a timer or shortening one
    /// immediately deletes every message older than the new window. Turning
    /// the timer off or lengthening it deletes nothing extra.
    static func requiresRetroactivePruneConfirmation(
        currentSeconds: UInt64,
        newSeconds: UInt64
    ) -> Bool {
        guard newSeconds > 0 else { return false }
        return currentSeconds == 0 || newSeconds < currentSeconds
    }

    enum CustomUnit: CaseIterable, Hashable {
        case seconds
        case minutes
        case hours
        case days
        case weeks

        var secondsPerUnit: UInt64 {
            switch self {
            case .seconds: 1
            case .minutes: 60
            case .hours: 60 * 60
            case .days: 24 * 60 * 60
            case .weeks: 7 * 24 * 60 * 60
            }
        }

        var label: String {
            switch self {
            case .seconds: L10n.string("Seconds")
            case .minutes: L10n.string("Minutes")
            case .hours: L10n.string("Hours")
            case .days: L10n.string("Days")
            case .weeks: L10n.string("Weeks")
            }
        }
    }

    /// Parses a typed custom duration. Returns `nil` for non-numeric input,
    /// zero, overflow, or values outside the allowed window.
    static func customSeconds(value: String, unit: CustomUnit) -> UInt64? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let amount = UInt64(trimmed), amount > 0 else { return nil }
        let (seconds, overflow) = amount.multipliedReportingOverflow(by: unit.secondsPerUnit)
        guard !overflow, (minCustomSeconds...maxCustomSeconds).contains(seconds) else { return nil }
        return seconds
    }

    /// Prefills the custom editor from an existing timer using the largest
    /// unit that divides it evenly. An off timer prefills empty.
    static func customDraft(forSeconds seconds: UInt64) -> (value: String, unit: CustomUnit) {
        guard seconds > 0 else { return ("", .minutes) }
        for unit in CustomUnit.allCases.reversed() where seconds.isMultiple(of: unit.secondsPerUnit) {
            return (String(seconds / unit.secondsPerUnit), unit)
        }
        return (String(seconds), .seconds)
    }

    static func compactLabel(seconds: UInt64, locale: Locale = AppLanguage.currentLocale) -> String {
        GroupSystemEventPresentation.retentionDurationText(seconds: seconds, locale: locale, unitsStyle: .abbreviated)
    }

    static func label(seconds: UInt64) -> String {
        GroupSystemEventPresentation.retentionSettingLabel(seconds: seconds)
    }
}
