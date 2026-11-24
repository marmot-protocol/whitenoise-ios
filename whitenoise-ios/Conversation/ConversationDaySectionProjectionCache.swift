import Foundation

struct TimelineDayHeadingsProjection: Equatable {
    let headings: [TimelineDateHeading]
    let orderedHeaderIDs: [String]
    let headersByID: [String: TimelineDateHeading]
    let headerIDByItemID: [String: String]
}

@MainActor
final class ConversationDaySectionProjectionCache {
    private struct CacheKey: Equatable {
        let generation: Int
        let today: Date
        let calendarIdentifier: Calendar.Identifier
        let timeZoneIdentifier: String
        let localeIdentifier: String
    }

    private var cached: (key: CacheKey, projection: TimelineDayHeadingsProjection)?

    func headingsProjection(
        for items: [TimelineItem],
        generation: Int,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent,
        now: Date = .now
    ) -> TimelineDayHeadingsProjection {
        let key = CacheKey(
            generation: generation,
            today: calendar.startOfDay(for: now),
            calendarIdentifier: calendar.identifier,
            timeZoneIdentifier: calendar.timeZone.identifier,
            localeIdentifier: locale.identifier
        )
        if let cached, cached.key == key {
            return cached.projection
        }

        var headings: [TimelineDateHeading] = []
        var orderedHeaderIDs: [String] = []
        var headersByID: [String: TimelineDateHeading] = [:]
        var headerIDByItemID: [String: String] = [:]
        headerIDByItemID.reserveCapacity(items.count)

        var lastDay: Date?
        var currentHeaderID: String?

        for item in items {
            let day = min(key.today, ConversationDateHeader.dayStart(timestamp: item.timestamp, calendar: calendar))
            if lastDay == day, let currentHeaderID {
                headerIDByItemID[item.id] = currentHeaderID
            } else {
                lastDay = day
                currentHeaderID = item.id
                let heading = TimelineDateHeading(id: item.id, day: day)
                headings.append(heading)
                orderedHeaderIDs.append(item.id)
                if headersByID[item.id] == nil {
                    headersByID[item.id] = heading
                }
                headerIDByItemID[item.id] = item.id
            }
        }
        let projection = TimelineDayHeadingsProjection(
            headings: headings,
            orderedHeaderIDs: orderedHeaderIDs,
            headersByID: headersByID,
            headerIDByItemID: headerIDByItemID
        )
        cached = (key, projection)
        return projection
    }
}
