import Foundation

/// Compact, glanceable timestamps for the chats list: recent times collapse
/// to localized "now"/minute/hour durations, this week shows the weekday,
/// older shows the date.
@MainActor
enum RelativeTime {
    private static var formatterCache: [String: DateFormatter] = [:]
    private static var durationFormatterCache: [String: DateComponentsFormatter] = [:]
    private static var formatterCacheLocaleIdentifier = Locale.autoupdatingCurrent.identifier
    private static let shortTimeFormatterKey = "style:time:short"

    static func short(
        _ date: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 0 { return L10n.string("now") }
        if seconds < 60 { return L10n.string("now") }
        if seconds < 3600 { return abbreviatedDuration(Int(seconds / 60), unit: .minute, locale: locale) }
        if calendar.isDate(date, inSameDayAs: now) {
            return abbreviatedDuration(Int(seconds / 3600), unit: .hour, locale: locale)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return L10n.string("Yesterday")
        }

        if seconds < 7 * 24 * 3600 {
            return formatted(date, "EEEE", locale: locale) // full weekday, e.g. "Monday"
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return formatted(date, sameYear ? "d MMM" : "d MMM yyyy", locale: locale)
    }

    static func shortTime(_ date: Date, locale: Locale = .autoupdatingCurrent) -> String {
        let formatter = formatter(for: shortTimeFormatterKey, locale: locale) { formatter in
            formatter.timeStyle = .short
            formatter.dateStyle = .none
        }
        return formatter.string(from: date)
    }

    private static func formatted(_ date: Date, _ template: String, locale: Locale) -> String {
        let formatter = formatter(for: template, locale: locale)
        return formatter.string(from: date)
    }

    private static func abbreviatedDuration(_ value: Int, unit: NSCalendar.Unit, locale: Locale) -> String {
        let formatter = durationFormatter(for: unit, locale: locale)
        let secondsPerUnit: TimeInterval = unit == .hour ? 3600 : 60
        let interval = TimeInterval(value) * secondsPerUnit
        return formatter.string(from: interval) ?? fallbackDuration(value, unit: unit, locale: locale)
    }

    private static func durationFormatter(
        for unit: NSCalendar.Unit,
        locale: Locale
    ) -> DateComponentsFormatter {
        let key = unit == .hour ? "duration:hour:abbreviated" : "duration:minute:abbreviated"
        refreshCachesIfNeeded(locale: locale)

        if let cached = durationFormatterCache[key] {
            return cached
        }

        let formatter = DateComponentsFormatter()
        var calendar = Calendar.autoupdatingCurrent
        calendar.locale = locale
        formatter.calendar = calendar
        formatter.allowedUnits = [unit]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 1
        durationFormatterCache[key] = formatter
        return formatter
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

    private static func formatter(for template: String, locale: Locale) -> DateFormatter {
        formatter(for: "template:\(template)", locale: locale) { formatter in
            formatter.setLocalizedDateFormatFromTemplate(template)
        }
    }

    private static func formatter(
        for key: String,
        locale: Locale,
        configure: (DateFormatter) -> Void
    ) -> DateFormatter {
        refreshCachesIfNeeded(locale: locale)

        if let cached = formatterCache[key] {
            return cached
        }

        let formatter = DateFormatter()
        formatter.locale = locale
        configure(formatter)
        formatterCache[key] = formatter
        return formatter
    }

    private static func refreshCachesIfNeeded(locale: Locale) {
        let localeIdentifier = locale.identifier
        if formatterCacheLocaleIdentifier != localeIdentifier {
            formatterCache.removeAll()
            durationFormatterCache.removeAll()
            formatterCacheLocaleIdentifier = localeIdentifier
        }
    }

    #if DEBUG
    static func resetFormatterCacheForTesting() {
        formatterCache.removeAll()
        durationFormatterCache.removeAll()
        formatterCacheLocaleIdentifier = Locale.autoupdatingCurrent.identifier
    }

    static var formatterCacheCountForTesting: Int {
        formatterCache.count
    }

    static var durationFormatterCacheCountForTesting: Int {
        durationFormatterCache.count
    }

    static var formatterCacheLocaleIdentifierForTesting: String {
        formatterCacheLocaleIdentifier
    }

    static func setFormatterCacheLocaleIdentifierForTesting(_ identifier: String) {
        formatterCacheLocaleIdentifier = identifier
    }

    #endif
}
