import Foundation

/// Compact, glanceable timestamps for the chats list — recent times collapse
/// to "now"/"4m"/"2h", this week shows the weekday, older shows the date.
@MainActor
enum RelativeTime {
    private static var formatterCache: [String: DateFormatter] = [:]
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
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if calendar.isDateInToday(date) { return "\(Int(seconds / 3600))h" }
        if calendar.isDateInYesterday(date) { return L10n.string("Yesterday") }

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
        let localeIdentifier = locale.identifier
        if formatterCacheLocaleIdentifier != localeIdentifier {
            formatterCache.removeAll()
            formatterCacheLocaleIdentifier = localeIdentifier
        }

        if let cached = formatterCache[key] {
            return cached
        }

        let formatter = DateFormatter()
        formatter.locale = locale
        configure(formatter)
        formatterCache[key] = formatter
        return formatter
    }

    #if DEBUG
    static func resetFormatterCacheForTesting() {
        formatterCache.removeAll()
        formatterCacheLocaleIdentifier = Locale.autoupdatingCurrent.identifier
    }

    static var formatterCacheCountForTesting: Int {
        formatterCache.count
    }

    static var formatterCacheLocaleIdentifierForTesting: String {
        formatterCacheLocaleIdentifier
    }

    static func setFormatterCacheLocaleIdentifierForTesting(_ identifier: String) {
        formatterCacheLocaleIdentifier = identifier
    }

    #endif
}
