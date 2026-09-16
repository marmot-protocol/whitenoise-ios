import Foundation

struct TimelineDaySection: Identifiable, Equatable {
    let day: Date
    var items: [TimelineItem]

    // Canonical protocol order can revisit the same calendar day.
    var id: String { items.first?.id ?? String(day.timeIntervalSince1970) }
}

@MainActor
final class ConversationDaySectionProjectionCache {
    private struct CacheKey: Equatable {
        let generation: Int
        let calendarIdentifier: Calendar.Identifier
        let timeZoneIdentifier: String
        let localeIdentifier: String
    }

    private var cached: (key: CacheKey, sections: [TimelineDaySection])?

#if DEBUG
    private(set) var buildCountForTesting = 0
#endif

    func sections(
        for items: [TimelineItem],
        generation: Int,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> [TimelineDaySection] {
        let key = CacheKey(
            generation: generation,
            calendarIdentifier: calendar.identifier,
            timeZoneIdentifier: calendar.timeZone.identifier,
            localeIdentifier: locale.identifier
        )
        if let cached, cached.key == key {
            return cached.sections
        }

#if DEBUG
        buildCountForTesting += 1
#endif
        var sections: [TimelineDaySection] = []
        for item in items {
            let day = ConversationDateHeader.dayStart(timestamp: item.timestamp, calendar: calendar)
            if sections.last?.day == day {
                sections[sections.count - 1].items.append(item)
            } else {
                sections.append(TimelineDaySection(day: day, items: [item]))
            }
        }
        cached = (key, sections)
        return sections
    }
}
