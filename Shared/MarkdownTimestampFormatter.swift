import Foundation
import MarmotKit

/// Renders MDK's `<t:UNIX_SECONDS:STYLE>` Markdown timestamps with the device's
/// current locale, time zone and 12/24-hour preference. MDK carries only the
/// instant and style; the formatted text is presentation state and must be
/// rebuilt when the locale, time zone or clock changes.
nonisolated enum MarkdownTimestampFormatter {
    /// 0001-01-02 through 9999-12-30 UTC: a day inside the four-digit
    /// Gregorian range, so no time zone can shift a rendering out of it
    /// (into year 0, an era-less negative year, or year 10000).
    static let renderableSeconds: ClosedRange<Int64> = -62_135_510_400...253_402_214_399

    static func isRenderable(_ unixSeconds: Int64) -> Bool {
        renderableSeconds.contains(unixSeconds)
    }

    /// The device locale with the in-app language override applied to the
    /// language only, so the region's date order and the 12/24-hour setting
    /// stay the device's.
    static var currentLocale: Locale {
        displayLocale(appLanguage: AppLanguage.current.locale?.language, device: .autoupdatingCurrent)
    }

    static func displayLocale(appLanguage: Locale.Language?, device: Locale) -> Locale {
        guard let appLanguage else { return device }
        var components = Locale.Components(locale: device)
        var language = Locale.Language.Components(language: appLanguage)
        // "de" alone would drop the device's region along with its language.
        language.region = language.region ?? components.languageComponents.region
        components.languageComponents = language
        // Components drop a preference-only hour cycle; keep the device's.
        components.hourCycle = device.hourCycle
        return Locale(components: components)
    }

    static func text(
        unixSeconds: Int64,
        style: MarkdownTimestampStyleFfi,
        now: Date = Date(),
        locale: Locale = currentLocale,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        guard isRenderable(unixSeconds) else {
            return literalToken(unixSeconds: unixSeconds, style: style)
        }
        let date = Date(timeIntervalSince1970: TimeInterval(unixSeconds))
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone

        let dateStyle: Date.FormatStyle.DateStyle
        let timeStyle: Date.FormatStyle.TimeStyle
        switch style {
        case .shortTime:
            (dateStyle, timeStyle) = (.omitted, .shortened)
        case .longTime:
            (dateStyle, timeStyle) = (.omitted, .standard)
        case .shortDate:
            (dateStyle, timeStyle) = (.numeric, .omitted)
        case .longDate:
            (dateStyle, timeStyle) = (.long, .omitted)
        case .shortDateTime:
            (dateStyle, timeStyle) = (.long, .shortened)
        case .longDateTime:
            (dateStyle, timeStyle) = (.complete, .shortened)
        case .compactDateTime:
            (dateStyle, timeStyle) = (.numeric, .shortened)
        case .compactDateTimeSeconds:
            (dateStyle, timeStyle) = (.numeric, .standard)
        case .relative:
            let relative = RelativeDateTimeFormatter()
            relative.locale = locale
            relative.calendar = calendar
            relative.unitsStyle = .full
            relative.dateTimeStyle = .named
            relative.formattingContext = .middleOfSentence
            return relative.localizedString(for: date, relativeTo: now)
        }
        return Date.FormatStyle(
            date: dateStyle,
            time: timeStyle,
            locale: locale,
            calendar: calendar,
            timeZone: timeZone
        ).format(date)
    }

    /// For one-line surfaces that are not refreshed while visible (chat-list
    /// rows, reply quotes, notifications): a relative phrase there would go
    /// stale, so it renders in the default absolute style instead.
    static func staticText(
        unixSeconds: Int64,
        style: MarkdownTimestampStyleFfi,
        locale: Locale = currentLocale,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        let absolute: MarkdownTimestampStyleFfi = isRelative(style) ? .shortDateTime : style
        guard isRenderable(unixSeconds) else {
            return literalToken(unixSeconds: unixSeconds, style: style)
        }
        return text(unixSeconds: unixSeconds, style: absolute, locale: locale, timeZone: timeZone)
    }

    /// Spoken form: always the absolute instant with its weekday, so a
    /// relative or time-only rendering still has an unambiguous description.
    static func accessibilityText(
        unixSeconds: Int64,
        locale: Locale = currentLocale,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        text(unixSeconds: unixSeconds, style: .longDateTime, locale: locale, timeZone: timeZone)
    }

    static func isRelative(_ style: MarkdownTimestampStyleFfi) -> Bool {
        if case .relative = style { return true }
        return false
    }

    /// Source spelling for an instant no calendar rendering can show, so it
    /// reads like the literal text MDK keeps for invalid timestamp syntax.
    static func literalToken(unixSeconds: Int64, style: MarkdownTimestampStyleFfi) -> String {
        "<t:\(unixSeconds):\(styleToken(style))>"
    }

    static func styleToken(_ style: MarkdownTimestampStyleFfi) -> Character {
        switch style {
        case .shortTime: "t"
        case .longTime: "T"
        case .shortDate: "d"
        case .longDate: "D"
        case .shortDateTime: "f"
        case .longDateTime: "F"
        case .compactDateTime: "s"
        case .compactDateTimeSeconds: "S"
        case .relative: "R"
        }
    }

    static func style(token: Character) -> MarkdownTimestampStyleFfi? {
        switch token {
        case "t": .shortTime
        case "T": .longTime
        case "d": .shortDate
        case "D": .longDate
        case "f": .shortDateTime
        case "F": .longDateTime
        case "s": .compactDateTime
        case "S": .compactDateTimeSeconds
        case "R": .relative
        default: nil
        }
    }
}
