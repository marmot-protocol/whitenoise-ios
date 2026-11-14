import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

@MainActor
struct RelativeTimeTests {

    @Test func chatListUsesLocalizedClockTimeForOlderMessagesToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let locale = Locale(identifier: "en_US")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let date = now.addingTimeInterval(-2 * 3600)
        let expectedFormatter = DateFormatter()
        expectedFormatter.locale = locale
        expectedFormatter.setLocalizedDateFormatFromTemplate("jm")

        #expect(RelativeTime.chatList(
            date,
            now: now,
            calendar: calendar,
            locale: locale,
            formatters: RelativeTimeFormatters()
        ) == expectedFormatter.string(from: date))
    }

    @Test func chatListKeepsLocalizedMinuteDurationForRecentMessages() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let locale = Locale(identifier: "fr_FR")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let expected = try expectedAbbreviatedDuration(4, unit: .minute, locale: locale)

        #expect(RelativeTime.chatList(
            now.addingTimeInterval(-4 * 60),
            now: now,
            calendar: calendar,
            locale: locale,
            formatters: RelativeTimeFormatters()
        ) == expected)
    }

    @Test func shortReusesCachedDateFormattersForRepeatedListRows() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let weekdayDate = now.addingTimeInterval(-3 * 24 * 3600)
        let olderDate = now.addingTimeInterval(-10 * 24 * 3600)

        let counter = RelativeTimeFormatterBuildCounter()

        for _ in 0..<50 {
            _ = RelativeTime.short(weekdayDate, now: now, calendar: calendar, formatters: counter.formatters)
        }
        #expect(counter.dateFormatterBuilds == 1)

        for _ in 0..<50 {
            _ = RelativeTime.short(olderDate, now: now, calendar: calendar, formatters: counter.formatters)
        }
        #expect(counter.dateFormatterBuilds == 2)
    }

    @Test func shortTimeReusesCachedDateFormatterForMessageBubbles() {
        let messageDate = Date(timeIntervalSince1970: 1_700_000_000)

        let counter = RelativeTimeFormatterBuildCounter()

        for _ in 0..<50 {
            _ = RelativeTime.shortTime(messageDate, formatters: counter.formatters)
        }

        #expect(counter.dateFormatterBuilds == 1)
    }

    @Test func shortReusesCachedDurationFormattersForRecentRows() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let minutesAgo = now.addingTimeInterval(-4 * 60)
        let hoursAgo = now.addingTimeInterval(-2 * 3600)

        let counter = RelativeTimeFormatterBuildCounter()

        for _ in 0..<50 {
            _ = RelativeTime.short(minutesAgo, now: now, calendar: calendar, formatters: counter.formatters)
        }
        #expect(counter.durationFormatterBuilds == 1)

        for _ in 0..<50 {
            _ = RelativeTime.short(hoursAgo, now: now, calendar: calendar, formatters: counter.formatters)
        }
        #expect(counter.durationFormatterBuilds == 2)
        #expect(counter.dateFormatterBuilds == 0)
    }

    @Test func shortRefreshesFormatterCacheWhenLocaleIdentifierChanges() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let weekdayDate = now.addingTimeInterval(-3 * 24 * 3600)
        let olderDate = now.addingTimeInterval(-30 * 24 * 3600)
        let recentDate = now.addingTimeInterval(-4 * 60)
        let english = Locale(identifier: "en_US")
        let french = Locale(identifier: "fr_FR")
        let counter = RelativeTimeFormatterBuildCounter()
        func short(_ date: Date, _ locale: Locale) -> String {
            RelativeTime.short(date, now: now, calendar: calendar, locale: locale, formatters: counter.formatters)
        }

        // English fills both date shapes and a duration; repeats reuse them.
        _ = short(weekdayDate, english)
        _ = short(olderDate, english)
        _ = short(recentDate, english)
        _ = short(weekdayDate, english)
        #expect(counter.dateFormatterBuilds == 2)
        #expect(counter.durationFormatterBuilds == 1)

        // A duration is the first French lookup: it clears every cached
        // formatter, so it and both date shapes rebuild in French.
        let frenchRecent = short(recentDate, french)
        #expect(counter.durationFormatterBuilds == 2)
        #expect(frenchRecent == (try expectedAbbreviatedDuration(4, unit: .minute, locale: french)))

        _ = short(weekdayDate, french)
        #expect(counter.dateFormatterBuilds == 3)
        #expect(counter.builtDateFormatters.last?.locale.identifier == french.identifier)

        let frenchOlder = short(olderDate, french)
        let expectedFormatter = DateFormatter()
        expectedFormatter.locale = french
        expectedFormatter.setLocalizedDateFormatFromTemplate("d MMM")
        #expect(counter.dateFormatterBuilds == 4)
        #expect(frenchOlder == expectedFormatter.string(from: olderDate))

        // Switching back with a date lookup first clears the duration too.
        _ = short(weekdayDate, english)
        #expect(counter.dateFormatterBuilds == 5)
        #expect(counter.builtDateFormatters.last?.locale.identifier == english.identifier)
        _ = short(recentDate, english)
        #expect(counter.durationFormatterBuilds == 3)
    }

    @Test func shortUsesLocalizedAbbreviatedDurationsForRecentRows() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let locale = Locale(identifier: "ar_EG")
        let formatters = RelativeTimeFormatters()

        let minuteLabel = RelativeTime.short(
            now.addingTimeInterval(-4 * 60),
            now: now,
            calendar: calendar,
            locale: locale,
            formatters: formatters
        )
        let hourLabel = RelativeTime.short(
            now.addingTimeInterval(-2 * 3600),
            now: now,
            calendar: calendar,
            locale: locale,
            formatters: formatters
        )

        let expectedMinute = try expectedAbbreviatedDuration(4, unit: .minute, locale: locale)
        let expectedHour = try expectedAbbreviatedDuration(2, unit: .hour, locale: locale)
        #expect(minuteLabel == expectedMinute)
        #expect(hourLabel == expectedHour)
        #expect(minuteLabel != "4m")
        #expect(hourLabel != "2h")
    }

    @Test func shortUsesLocalizedDateTemplateOrderingForOlderDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 2,
            day: 10,
            hour: 12
        )))
        let now = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 2,
            day: 20,
            hour: 12
        )))
        let locale = Locale(identifier: "en_US")
        let expectedFormatter = DateFormatter()
        expectedFormatter.locale = locale
        expectedFormatter.setLocalizedDateFormatFromTemplate("d MMM")

        let rendered = RelativeTime.short(
            date,
            now: now,
            calendar: calendar,
            locale: locale,
            formatters: RelativeTimeFormatters()
        )
        let expected = expectedFormatter.string(from: date)
        #expect(rendered == expected)
    }

    @Test func shortDefaultsToInAppLanguageLocaleForFormattedLabels() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 2,
            day: 10,
            hour: 12
        )))
        let now = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 2,
            day: 20,
            hour: 12
        )))

        withAppLanguage(.french) {
            let counter = RelativeTimeFormatterBuildCounter()
            let expectedFormatter = DateFormatter()
            expectedFormatter.locale = AppLanguage.currentLocale
            expectedFormatter.setLocalizedDateFormatFromTemplate("d MMM")

            #expect(RelativeTime.short(date, now: now, calendar: calendar, formatters: counter.formatters)
                == expectedFormatter.string(from: date))
            #expect(counter.builtDateFormatters.last?.locale.identifier == AppLanguage.currentLocale.identifier)
        }
    }

    @Test func shortTimeDefaultsToInAppLanguageLocale() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        withAppLanguage(.french) {
            let counter = RelativeTimeFormatterBuildCounter()
            let expectedFormatter = DateFormatter()
            expectedFormatter.locale = AppLanguage.currentLocale
            expectedFormatter.setLocalizedDateFormatFromTemplate("hmm a")

            #expect(RelativeTime.shortTime(date, formatters: counter.formatters)
                == expectedFormatter.string(from: date))
            #expect(counter.builtDateFormatters.last?.locale.identifier == AppLanguage.currentLocale.identifier)
        }
    }

    @Test func messageBubbleTimeLabelUsesCachedFormatter() {
        let timestamp: UInt64 = 1_700_000_000

        let counter = RelativeTimeFormatterBuildCounter()

        for _ in 0..<50 {
            _ = MessageBubble.timeLabel(recordedAt: timestamp, formatters: counter.formatters)
        }

        #expect(counter.dateFormatterBuilds == 1)
    }

    private func expectedAbbreviatedDuration(
        _ value: Int,
        unit: NSCalendar.Unit,
        locale: Locale
    ) throws -> String {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar.autoupdatingCurrent
        calendar.locale = locale
        formatter.calendar = calendar
        formatter.allowedUnits = [unit]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 1

        let secondsPerUnit: TimeInterval = unit == .hour ? 3600 : 60
        return try #require(formatter.string(from: TimeInterval(value) * secondsPerUnit))
    }
}
