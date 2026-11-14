import Foundation

/// Compact, glanceable timestamps for the chats list: recent times collapse
/// to localized "now"/minute/hour durations, this week shows the weekday,
/// older shows the date.
@MainActor
enum RelativeTime {
    static func short(
        _ date: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = AppLanguage.currentLocale,
        formatters: RelativeTimeFormatters = .shared
    ) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 0 { return L10n.string("now") }
        if seconds < 60 { return L10n.string("now") }
        if seconds < 3600 {
            return abbreviatedDuration(Int(seconds / 60), unit: .minute, locale: locale, formatters: formatters)
        }
        if calendar.isDate(date, inSameDayAs: now) {
            return abbreviatedDuration(Int(seconds / 3600), unit: .hour, locale: locale, formatters: formatters)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return L10n.string("Yesterday")
        }

        if seconds < 7 * 24 * 3600 {
            return formatted(date, "EEEE", locale: locale, formatters: formatters) // full weekday, e.g. "Monday"
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return formatted(date, sameYear ? "d MMM" : "d MMM yyyy", locale: locale, formatters: formatters)
    }

    static func chatList(
        _ date: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = AppLanguage.currentLocale,
        formatters: RelativeTimeFormatters = .shared
    ) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return L10n.string("now") }
        if seconds < 3600 {
            return abbreviatedDuration(Int(seconds / 60), unit: .minute, locale: locale, formatters: formatters)
        }
        if calendar.isDate(date, inSameDayAs: now) {
            return formatted(date, "jm", locale: locale, formatters: formatters)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return L10n.string("Yesterday")
        }
        if seconds < 7 * 24 * 3600 {
            return formatted(date, "EEEE", locale: locale, formatters: formatters)
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return formatted(date, sameYear ? "d MMM" : "d MMM yyyy", locale: locale, formatters: formatters)
    }

    static func shortTime(
        _ date: Date,
        locale: Locale = AppLanguage.currentLocale,
        formatters: RelativeTimeFormatters = .shared
    ) -> String {
        // Bubble times always carry the 12-hour day period ("9:41 PM"),
        // regardless of the device's 24-hour setting; the localized template
        // keeps element order and the period's spelling locale-correct.
        formatted(date, "hmm a", locale: locale, formatters: formatters)
    }

    private static func formatted(
        _ date: Date,
        _ template: String,
        locale: Locale,
        formatters: RelativeTimeFormatters
    ) -> String {
        let formatter = formatters.dateFormatter(template: template, locale: locale)
        return formatter.string(from: date)
    }

    private static func abbreviatedDuration(
        _ value: Int,
        unit: NSCalendar.Unit,
        locale: Locale,
        formatters: RelativeTimeFormatters
    ) -> String {
        let formatter = formatters.durationFormatter(for: unit, locale: locale)
        let secondsPerUnit: TimeInterval = unit == .hour ? 3600 : 60
        let interval = TimeInterval(value) * secondsPerUnit
        return formatter.string(from: interval) ?? fallbackDuration(value, unit: unit, locale: locale)
    }

    private static func fallbackDuration(_ value: Int, unit: NSCalendar.Unit, locale: Locale) -> String {
        let measurementFormatter = MeasurementFormatter()
        measurementFormatter.locale = locale
        measurementFormatter.unitStyle = .short

        let numberFormatter = NumberFormatter()
        numberFormatter.locale = locale
        numberFormatter.numberStyle = .decimal
        measurementFormatter.numberFormatter = numberFormatter

        let durationUnit: UnitDuration = unit == .hour ? .hours : .minutes
        return measurementFormatter.string(from: Measurement(value: Double(value), unit: durationUnit))
    }
}

/// Caches the date and duration formatters `RelativeTime` builds, per locale.
@MainActor
final class RelativeTimeFormatters {
    static let shared = RelativeTimeFormatters()

    private let makeDateFormatter: @MainActor () -> DateFormatter
    private let makeDurationFormatter: @MainActor () -> DateComponentsFormatter
    private var formatterCache: [String: DateFormatter] = [:]
    private var durationFormatterCache: [String: DateComponentsFormatter] = [:]
    private var formatterCacheLocaleIdentifier = Locale.autoupdatingCurrent.identifier

    init(
        makeDateFormatter: @escaping @MainActor () -> DateFormatter = { DateFormatter() },
        makeDurationFormatter: @escaping @MainActor () -> DateComponentsFormatter = { DateComponentsFormatter() }
    ) {
        self.makeDateFormatter = makeDateFormatter
        self.makeDurationFormatter = makeDurationFormatter
    }

    func durationFormatter(
        for unit: NSCalendar.Unit,
        locale: Locale
    ) -> DateComponentsFormatter {
        let key = unit == .hour ? "duration:hour:abbreviated" : "duration:minute:abbreviated"
        refreshCachesIfNeeded(locale: locale)

        if let cached = durationFormatterCache[key] {
            return cached
        }

        let formatter = makeDurationFormatter()
        var calendar = Calendar.autoupdatingCurrent
        calendar.locale = locale
        formatter.calendar = calendar
        formatter.allowedUnits = [unit]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 1
        durationFormatterCache[key] = formatter
        return formatter
    }

    func dateFormatter(template: String, locale: Locale) -> DateFormatter {
        formatter(for: "template:\(template)", locale: locale) { formatter in
            formatter.setLocalizedDateFormatFromTemplate(template)
        }
    }

    private func formatter(
        for key: String,
        locale: Locale,
        configure: (DateFormatter) -> Void
    ) -> DateFormatter {
        refreshCachesIfNeeded(locale: locale)

        if let cached = formatterCache[key] {
            return cached
        }

        let formatter = makeDateFormatter()
        formatter.locale = locale
        configure(formatter)
        formatterCache[key] = formatter
        return formatter
    }

    private func refreshCachesIfNeeded(locale: Locale) {
        let localeIdentifier = locale.identifier
        if formatterCacheLocaleIdentifier != localeIdentifier {
            formatterCache.removeAll()
            durationFormatterCache.removeAll()
            formatterCacheLocaleIdentifier = localeIdentifier
        }
    }
}
