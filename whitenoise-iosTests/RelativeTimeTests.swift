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
            locale: locale
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
            locale: locale
        ) == expected)
    }

    @Test func shortReusesCachedDateFormattersForRepeatedListRows() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let weekdayDate = now.addingTimeInterval(-3 * 24 * 3600)
        let olderDate = now.addingTimeInterval(-10 * 24 * 3600)

        RelativeTime.resetFormatterCacheForTesting()
        defer { RelativeTime.resetFormatterCacheForTesting() }

        for _ in 0..<50 {
            _ = RelativeTime.short(weekdayDate, now: now, calendar: calendar)
        }
        #expect(RelativeTime.formatterCacheCountForTesting == 1)

        for _ in 0..<50 {
            _ = RelativeTime.short(olderDate, now: now, calendar: calendar)
        }
        #expect(RelativeTime.formatterCacheCountForTesting == 2)
    }

    @Test func shortTimeReusesCachedDateFormatterForMessageBubbles() {
        let messageDate = Date(timeIntervalSince1970: 1_700_000_000)

        RelativeTime.resetFormatterCacheForTesting()
        defer { RelativeTime.resetFormatterCacheForTesting() }

        for _ in 0..<50 {
            _ = RelativeTime.shortTime(messageDate)
        }

        #expect(RelativeTime.formatterCacheCountForTesting == 1)
    }

    @Test func shortReusesCachedDurationFormattersForRecentRows() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let minutesAgo = now.addingTimeInterval(-4 * 60)
        let hoursAgo = now.addingTimeInterval(-2 * 3600)

        RelativeTime.resetFormatterCacheForTesting()
        defer { RelativeTime.resetFormatterCacheForTesting() }

        for _ in 0..<50 {
            _ = RelativeTime.short(minutesAgo, now: now, calendar: calendar)
        }
        #expect(RelativeTime.durationFormatterCacheCountForTesting == 1)

        for _ in 0..<50 {
            _ = RelativeTime.short(hoursAgo, now: now, calendar: calendar)
        }
        #expect(RelativeTime.durationFormatterCacheCountForTesting == 2)
        #expect(RelativeTime.formatterCacheCountForTesting == 0)
    }

    @Test func shortRefreshesFormatterCacheWhenLocaleIdentifierChanges() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let weekdayDate = now.addingTimeInterval(-3 * 24 * 3600)
        let olderDate = now.addingTimeInterval(-10 * 24 * 3600)

        RelativeTime.resetFormatterCacheForTesting()
        defer { RelativeTime.resetFormatterCacheForTesting() }

        _ = RelativeTime.short(weekdayDate, now: now, calendar: calendar)
        _ = RelativeTime.short(olderDate, now: now, calendar: calendar)
        #expect(RelativeTime.formatterCacheCountForTesting == 2)

        RelativeTime.setFormatterCacheLocaleIdentifierForTesting("stale-locale")
        _ = RelativeTime.short(weekdayDate, now: now, calendar: calendar)

        #expect(RelativeTime.formatterCacheCountForTesting == 1)
        #expect(RelativeTime.formatterCacheLocaleIdentifierForTesting == AppLanguage.currentLocale.identifier)
    }

    @Test func shortUsesLocalizedAbbreviatedDurationsForRecentRows() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let locale = Locale(identifier: "ar_EG")

        RelativeTime.resetFormatterCacheForTesting()
        defer { RelativeTime.resetFormatterCacheForTesting() }

        let minuteLabel = RelativeTime.short(
            now.addingTimeInterval(-4 * 60),
            now: now,
            calendar: calendar,
            locale: locale
        )
        let hourLabel = RelativeTime.short(
            now.addingTimeInterval(-2 * 3600),
            now: now,
            calendar: calendar,
            locale: locale
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

        RelativeTime.resetFormatterCacheForTesting()
        defer { RelativeTime.resetFormatterCacheForTesting() }

        let rendered = RelativeTime.short(date, now: now, calendar: calendar, locale: locale)
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
            RelativeTime.resetFormatterCacheForTesting()
            defer { RelativeTime.resetFormatterCacheForTesting() }

            let expectedFormatter = DateFormatter()
            expectedFormatter.locale = AppLanguage.currentLocale
            expectedFormatter.setLocalizedDateFormatFromTemplate("d MMM")

            #expect(RelativeTime.short(date, now: now, calendar: calendar) == expectedFormatter.string(from: date))
            #expect(RelativeTime.formatterCacheLocaleIdentifierForTesting == AppLanguage.currentLocale.identifier)
        }
    }

    @Test func shortTimeDefaultsToInAppLanguageLocale() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        withAppLanguage(.french) {
            RelativeTime.resetFormatterCacheForTesting()
            defer { RelativeTime.resetFormatterCacheForTesting() }

            let expectedFormatter = DateFormatter()
            expectedFormatter.locale = AppLanguage.currentLocale
            expectedFormatter.setLocalizedDateFormatFromTemplate("hmm a")

            #expect(RelativeTime.shortTime(date) == expectedFormatter.string(from: date))
            #expect(RelativeTime.formatterCacheLocaleIdentifierForTesting == AppLanguage.currentLocale.identifier)
        }
    }

    @Test func messageBubbleTimeLabelUsesCachedFormatter() {
        let timestamp: UInt64 = 1_700_000_000

        RelativeTime.resetFormatterCacheForTesting()
        defer { RelativeTime.resetFormatterCacheForTesting() }

        for _ in 0..<50 {
            _ = MessageBubble.timeLabel(recordedAt: timestamp)
        }

        #expect(RelativeTime.formatterCacheCountForTesting == 1)
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
