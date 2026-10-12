import Foundation
import MarmotKit

/// Renders MDK's `<t:UNIX_SECONDS:STYLE>` Markdown timestamps with the device's
/// current locale, time zone and 12/24-hour preference. MDK carries only the
/// instant and style; the formatted text is presentation state and must be
/// rebuilt when the locale, time zone or clock changes.
nonisolated enum MarkdownTimestampFormatter {
    /// Year 9999's last second. Anything outside ±this has no useful
    /// calendar rendering, so it shows the raw number instead.
    static let maxRenderableSeconds: Int64 = 253_402_300_799

    static func text(
        unixSeconds: Int64,
        style: MarkdownTimestampStyleFfi,
        now: Date = Date(),
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        guard unixSeconds.magnitude <= UInt64(maxRenderableSeconds) else { return String(unixSeconds) }
        let date = Date(timeIntervalSince1970: TimeInterval(unixSeconds))
        var calendar = Calendar.autoupdatingCurrent
        calendar.locale = locale
        calendar.timeZone = timeZone

        var format: Date.FormatStyle
        switch style {
        case .shortTime:
            format = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar)
        case .longTime:
            format = Date.FormatStyle(date: .omitted, time: .standard, locale: locale, calendar: calendar)
        case .shortDate:
            format = Date.FormatStyle(date: .numeric, time: .omitted, locale: locale, calendar: calendar)
        case .longDate:
            format = Date.FormatStyle(date: .long, time: .omitted, locale: locale, calendar: calendar)
        case .shortDateTime:
            format = Date.FormatStyle(date: .long, time: .shortened, locale: locale, calendar: calendar)
        case .longDateTime:
            format = Date.FormatStyle(date: .complete, time: .shortened, locale: locale, calendar: calendar)
        case .compactDateTime:
            format = Date.FormatStyle(date: .numeric, time: .shortened, locale: locale, calendar: calendar)
        case .compactDateTimeSeconds:
            format = Date.FormatStyle(date: .numeric, time: .standard, locale: locale, calendar: calendar)
        case .relative:
            let relative = RelativeDateTimeFormatter()
            relative.locale = locale
            relative.calendar = calendar
            relative.unitsStyle = .full
            relative.dateTimeStyle = .named
            relative.formattingContext = .middleOfSentence
            return relative.localizedString(for: date, relativeTo: now)
        }
        format.timeZone = timeZone
        return format.format(date)
    }

    /// Spoken and tooltip form: always the absolute instant, so a relative
    /// rendering still has an unambiguous description.
    static func accessibilityText(
        unixSeconds: Int64,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        text(unixSeconds: unixSeconds, style: .longDateTime, locale: locale, timeZone: timeZone)
    }

    static func isRelative(_ style: MarkdownTimestampStyleFfi) -> Bool {
        if case .relative = style { return true }
        return false
    }
}
