import Foundation

extension MarkdownTimestamp {
    nonisolated func label(now: Date = .now, locale: Locale = .autoupdatingCurrent,
                           timeZone: TimeZone = .autoupdatingCurrent) -> String {
        guard style == .relative else { return absoluteLabel(locale: locale, timeZone: timeZone) }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .numeric
        return formatter.localizedString(from: relativeComponents(now: now))
    }

    nonisolated static func plainText(_ source: AttributedString, now: Date = .now) -> String {
        project(source) { $0.label(now: now) }
    }

    nonisolated func disclosure(locale: Locale = .autoupdatingCurrent,
                               timeZone: TimeZone = .autoupdatingCurrent) -> String {
        MarkdownTimestamp(unixSeconds: unixSeconds, style: .longDateTime)
            .absoluteLabel(locale: locale, timeZone: timeZone) + "\n" + token
    }
}
