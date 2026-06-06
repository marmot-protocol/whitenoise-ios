import Foundation

/// Compact, glanceable timestamps for the chats list — recent times collapse
/// to "now"/"4m"/"2h", this week shows the weekday, older shows the date.
@MainActor
enum RelativeTime {
    private static var formatterCache: [String: DateFormatter] = [:]
    private static var formatterCacheLocaleIdentifier = Locale.autoupdatingCurrent.identifier

    static func short(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 0 { return L10n.string("now") }
        if seconds < 60 { return L10n.string("now") }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if calendar.isDateInToday(date) { return "\(Int(seconds / 3600))h" }
        if calendar.isDateInYesterday(date) { return L10n.string("Yesterday") }

        if seconds < 7 * 24 * 3600 {
            return formatted(date, "EEEE") // full weekday, e.g. "Monday"
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return formatted(date, sameYear ? "d MMM" : "d MMM yyyy")
    }

    private static func formatted(_ date: Date, _ template: String) -> String {
        let formatter = formatter(for: template)
        return formatter.string(from: date)
    }

    private static func formatter(for template: String) -> DateFormatter {
        let locale = Locale.autoupdatingCurrent
        let localeIdentifier = locale.identifier
        if formatterCacheLocaleIdentifier != localeIdentifier {
            formatterCache.removeAll()
            formatterCacheLocaleIdentifier = localeIdentifier
        }

        if let cached = formatterCache[template] {
            return cached
        }

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = template
        formatterCache[template] = formatter
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
