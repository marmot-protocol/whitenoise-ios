import Foundation
import SwiftUI
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

/// MDK hands the host an instant and a style; the host formats it with the
/// device's locale, time zone and hour cycle and keeps it fresh.
@MainActor
struct MarkdownTimestampTests {
    /// 2026-01-01 13:05:09 UTC, a Thursday.
    private let instant: Int64 = 1_767_272_709
    private let utc = TimeZone(identifier: "UTC")!
    private let enUS = Locale(identifier: "en_US")
    private let deDE = Locale(identifier: "de_DE")

    /// ICU separates the day period with a narrow no-break space on some
    /// releases; compare the visible text.
    private func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    private func format(
        _ style: MarkdownTimestampStyleFfi,
        _ seconds: Int64? = nil,
        locale: Locale,
        timeZone: TimeZone? = nil,
        now: Date? = nil
    ) -> String {
        normalized(MarkdownTimestampFormatter.text(
            unixSeconds: seconds ?? instant,
            style: style,
            now: now ?? Date(timeIntervalSince1970: TimeInterval(instant)),
            locale: locale,
            timeZone: timeZone ?? utc
        ))
    }

    // MARK: - Styles

    @Test func everyStyleFollowsTheEnglishUSConventions() {
        #expect(format(.shortTime, locale: enUS) == "1:05 PM")
        #expect(format(.longTime, locale: enUS) == "1:05:09 PM")
        #expect(format(.shortDate, locale: enUS) == "1/1/2026")
        #expect(format(.longDate, locale: enUS) == "January 1, 2026")
        #expect(format(.shortDateTime, locale: enUS) == "January 1, 2026 at 1:05 PM")
        #expect(format(.longDateTime, locale: enUS) == "Thursday, January 1, 2026 at 1:05 PM")
        #expect(format(.compactDateTime, locale: enUS) == "1/1/2026, 1:05 PM")
        #expect(format(.compactDateTimeSeconds, locale: enUS) == "1/1/2026, 1:05:09 PM")
    }

    @Test func everyStyleFollowsTheGermanConventions() {
        #expect(format(.shortTime, locale: deDE) == "13:05")
        #expect(format(.longTime, locale: deDE) == "13:05:09")
        #expect(format(.shortDate, locale: deDE) == "1.1.2026")
        #expect(format(.longDate, locale: deDE) == "1. Januar 2026")
        #expect(format(.shortDateTime, locale: deDE) == "1. Januar 2026 um 13:05")
        #expect(format(.longDateTime, locale: deDE) == "Donnerstag, 1. Januar 2026 um 13:05")
        #expect(format(.compactDateTime, locale: deDE) == "1.1.2026, 13:05")
        #expect(format(.compactDateTimeSeconds, locale: deDE) == "1.1.2026, 13:05:09")
    }

    @Test func relativeStyleMeasuresFromTheSuppliedClock() {
        let now = Date(timeIntervalSince1970: TimeInterval(instant))
        #expect(format(.relative, locale: enUS, now: now.addingTimeInterval(7_200)) == "2 hours ago")
        #expect(format(.relative, locale: enUS, now: now.addingTimeInterval(-300)) == "in 5 minutes")
        #expect(format(.relative, locale: deDE, now: now.addingTimeInterval(7_200)) == "vor 2 Stunden")
        #expect(format(.relative, locale: deDE, now: now.addingTimeInterval(-300)) == "in 5 Minuten")
    }

    @Test func hourCyclePreferenceOverridesTheRegionDefault() {
        let en24 = Locale(identifier: "en_US@hours=h23")
        let de12 = Locale(identifier: "de_DE@hours=h12")
        #expect(format(.shortTime, locale: en24) == "13:05")
        #expect(format(.compactDateTimeSeconds, locale: en24) == "1/1/2026, 13:05:09")
        let german12 = format(.shortTime, locale: de12)
        #expect(german12.hasPrefix("1:05"))
        #expect(!german12.contains("13"))
    }

    @Test func timeZoneChangesTheWallClockReading() {
        let newYork = TimeZone(identifier: "America/New_York")!
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        #expect(format(.shortTime, locale: enUS, timeZone: newYork) == "8:05 AM")
        #expect(format(.shortTime, locale: enUS, timeZone: tokyo) == "10:05 PM")
        #expect(format(.shortDate, locale: enUS, timeZone: TimeZone(identifier: "Pacific/Kiritimati")!) == "1/2/2026")
    }

    @Test func appLanguageReplacesOnlyTheLanguageOfTheDeviceLocale() {
        var device = Locale.Components(locale: Locale(identifier: "en_US"))
        device.hourCycle = .zeroToTwentyThree
        let deviceLocale = Locale(components: device)

        #expect(MarkdownTimestampFormatter.displayLocale(appLanguage: nil, device: deviceLocale) == deviceLocale)

        let merged = MarkdownTimestampFormatter.displayLocale(
            appLanguage: Locale.Language(identifier: "de"),
            device: deviceLocale
        )
        #expect(merged.language.languageCode == .german)
        #expect(merged.region == .unitedStates)
        #expect(merged.hourCycle == .zeroToTwentyThree)
        #expect(format(.shortTime, locale: merged) == "13:05")
    }

    // MARK: - Range, static and spoken forms

    @Test func outOfRangeInstantsStayLiteralSource() {
        for (seconds, style) in [
            (Int64.max, MarkdownTimestampStyleFfi.relative),
            (Int64.min, .shortDateTime),
            (MarkdownTimestampFormatter.renderableSeconds.upperBound + 1, .longDate),
            (MarkdownTimestampFormatter.renderableSeconds.lowerBound - 1, .shortTime),
        ] {
            let expected = MarkdownTimestampFormatter.literalToken(unixSeconds: seconds, style: style)
            #expect(format(style, seconds, locale: enUS) == expected)
            #expect(MarkdownTimestampFormatter.staticText(unixSeconds: seconds, style: style, locale: enUS, timeZone: utc) == expected)
        }
        #expect(MarkdownTimestampFormatter.literalToken(unixSeconds: -5, style: .relative) == "<t:-5:R>")
    }

    @Test func renderableBoundsKeepFourDigitYearsInExtremeTimeZones() {
        let east = TimeZone(identifier: "Pacific/Kiritimati")!
        let west = TimeZone(identifier: "Etc/GMT+12")!
        let upper = MarkdownTimestampFormatter.renderableSeconds.upperBound
        let lower = MarkdownTimestampFormatter.renderableSeconds.lowerBound
        #expect(format(.longDate, upper, locale: enUS, timeZone: east) == "December 31, 9999")
        // Foundation's Gregorian calendar is Julian before 1582, so year 1
        // reads a couple of days later than the proleptic date; the year holds.
        let earliest = format(.longDate, lower, locale: enUS, timeZone: west)
        #expect(earliest.hasPrefix("January "))
        #expect(earliest.hasSuffix(", 1"))
    }

    @Test func staticSurfacesRenderRelativeAsTheDefaultAbsoluteStyle() {
        let staticRelative = MarkdownTimestampFormatter.staticText(
            unixSeconds: instant, style: .relative, locale: enUS, timeZone: utc
        )
        #expect(normalized(staticRelative) == format(.shortDateTime, locale: enUS))
        let staticTime = MarkdownTimestampFormatter.staticText(
            unixSeconds: instant, style: .shortTime, locale: enUS, timeZone: utc
        )
        #expect(normalized(staticTime) == "1:05 PM")
    }

    @Test func accessibilityTextIsTheAbsoluteInstantWithWeekday() {
        let spoken = MarkdownTimestampFormatter.accessibilityText(unixSeconds: instant, locale: enUS, timeZone: utc)
        #expect(normalized(spoken) == "Thursday, January 1, 2026 at 1:05 PM")
    }

    @Test func styleTokensRoundTrip() {
        for token in "tTdDfFsSR" {
            let style = MarkdownTimestampFormatter.style(token: token)
            #expect(style != nil)
            #expect(style.map(MarkdownTimestampFormatter.styleToken) == token)
        }
        #expect(MarkdownTimestampFormatter.style(token: "r") == nil)
    }

    // MARK: - Raw-text tokens (notification previews)

    private func replaced(_ raw: String, max: Int = MarkdownTimestampTokenText.maxReplacements) -> String {
        MarkdownTimestampTokenText.replacingTokens(in: raw, maxReplacements: max) { seconds, style in
            "[\(seconds)|\(MarkdownTimestampFormatter.styleToken(style))]"
        }
    }

    @Test func rawTokensFollowMDKGrammar() {
        #expect(replaced("Meet <t:1767272709:t>!") == "Meet [1767272709|t]!")
        #expect(replaced("<t:5>") == "[5|f]")
        #expect(replaced("<t:-5:R> <t:0001:F>") == "[-5|R] [1|F]")
        for literal in [
            "<t:>", "<t::R>", "<t:-:R>", "<t:+1:R>", "<t:1.5:R>", "<t:1:r>", "<t:1:x>",
            "<t:1:>", "<t:1:RR>", "<t: 1:R>", "<t:1:R", "<T:1:R>", "<t:١:R>",
            "<t:9223372036854775808:R>", "<t:-9223372036854775809:R>",
        ] {
            #expect(replaced(literal) == literal)
        }
    }

    @Test func escapedAndCodeSpanTokensStayLiteral() {
        #expect(replaced(#"\<t:1:R>"#) == #"\<t:1:R>"#)
        #expect(replaced("`<t:1:R>` and <t:2:R>") == "`<t:1:R>` and [2|R]")
        #expect(replaced("``a ` <t:1:R>`` <t:2:R>") == "``a ` <t:1:R>`` [2|R]")
        #expect(replaced("unclosed ` <t:3:R>") == "unclosed ` [3|R]")
    }

    @Test func rawReplacementIsBounded() {
        let raw = String(repeating: "<t:1:R>", count: 5)
        #expect(replaced(raw, max: 2) == "[1|R][1|R]<t:1:R><t:1:R><t:1:R>")
    }

    @Test func notificationPreviewsUseStaticAbsoluteText() {
        let raw = "Call <t:\(instant):R>"
        let expected = "Call " + MarkdownTimestampFormatter.staticText(unixSeconds: instant, style: .relative)
        #expect(MarkdownTimestampTokenText.replacingTokens(in: raw) == expected)
    }

    // MARK: - Previews and display blocks

    private func doc(_ inlines: [MarkdownInlineFfi]) -> MarkdownDocumentFfi {
        MarkdownDocumentFfi(blocks: [.paragraph(inlines: inlines)], truncated: false)
    }

    @Test func plainTextPreviewsNeverShowRelativePhrases() {
        let flattened = MarkdownPlainText.flatten(doc([
            .text(content: "Starts"),
            .timestamp(unixSeconds: instant, style: .relative),
        ]))
        let absolute = MarkdownTimestampFormatter.staticText(unixSeconds: instant, style: .relative)
        #expect(flattened.map(normalized) == normalized("Starts \(absolute)"))
    }

    private var context: MarkdownTimestampRenderContext {
        MarkdownTimestampRenderContext(
            now: Date(timeIntervalSince1970: TimeInterval(instant) - 300),
            locale: enUS,
            timeZone: utc
        )
    }

    @Test func displayRunIsSubtlyStyledAndCarriesItsSpokenInstant() throws {
        let built = MarkdownMessageBuilder.build(
            for: doc([.text(content: "Starts "), .timestamp(unixSeconds: instant, style: .relative)]),
            timestampContext: context
        )
        let blocks = try #require(built.blocks)
        guard case .paragraph(let text) = try #require(blocks.first) else {
            Issue.record("expected a paragraph")
            return
        }
        #expect(String(text.characters) == "Starts in 5 minutes")
        let run = try #require(text.runs.first { $0[MarkdownTimestampDescriptionAttribute.self] != nil })
        #expect(run.backgroundColor != nil)
        #expect(run.font == Font.body.monospacedDigit())
        #expect(normalized(run[MarkdownTimestampDescriptionAttribute.self] ?? "")
            == "Thursday, January 1, 2026 at 1:05 PM")
        #expect(MarkdownTimestampDescriptionAttribute.descriptions(in: text).count == 1)
        #expect(built.timestamps.containsTimestamps)
        #expect(built.timestamps.relativeUnixSeconds == [instant])
    }

    @Test func unrenderableInstantIsPlainLiteralText() throws {
        let built = MarkdownMessageBuilder.build(
            for: doc([.timestamp(unixSeconds: .max, style: .relative)]),
            timestampContext: context
        )
        guard case .paragraph(let text) = try #require(built.blocks?.first) else {
            Issue.record("expected a paragraph")
            return
        }
        #expect(String(text.characters) == "<t:\(Int64.max):R>")
        #expect(MarkdownTimestampDescriptionAttribute.descriptions(in: text).isEmpty)
        #expect(built.timestamps.containsTimestamps)
        #expect(!built.timestamps.containsRelative)
    }

    @Test func usageTracksOnlyAbsoluteWhenNoRelativeStyleIsPresent() {
        let built = MarkdownMessageBuilder.build(
            for: doc([.timestamp(unixSeconds: instant, style: .shortTime)]),
            timestampContext: context
        )
        #expect(built.timestamps.containsTimestamps)
        #expect(!built.timestamps.containsRelative)
        let plain = MarkdownMessageBuilder.build(for: doc([.text(content: "hi")]))
        #expect(!plain.timestamps.containsTimestamps)
    }

    // MARK: - Cache invalidation

    @Test func cachePolicyRebuildsOnlyTimestampRowsFromAnotherGeneration() {
        #expect(MarkdownTimestampCachePolicy.needsRebuild(containsTimestamps: true, builtGeneration: 1, currentGeneration: 2))
        #expect(MarkdownTimestampCachePolicy.needsRebuild(containsTimestamps: true, builtGeneration: nil, currentGeneration: 0))
        #expect(!MarkdownTimestampCachePolicy.needsRebuild(containsTimestamps: true, builtGeneration: 2, currentGeneration: 2))
        #expect(!MarkdownTimestampCachePolicy.needsRebuild(containsTimestamps: false, builtGeneration: 1, currentGeneration: 2))
    }

    private func item(_ id: String, _ inlines: [MarkdownInlineFfi]) -> TimelineItem {
        TimelineItem.message(AppMessageRecordFfi(
            messageIdHex: id,
            direction: "received",
            groupIdHex: "group",
            sender: "sender",
            plaintext: "text",
            contentTokens: doc(inlines),
            kind: 9,
            tags: [],
            recordedAt: 1,
            receivedAt: 1
        ))
    }

    @Test func generationChangeRebuildsTimestampRowsOnly() {
        let cache = ConversationMarkdownProjectionCache()
        let plain = item("plain", [.text(content: "hello")])
        let stamped = item("stamped", [.timestamp(unixSeconds: instant, style: .shortTime)])
        let relative = item("relative", [.timestamp(unixSeconds: instant, style: .relative)])
        let items = [plain, stamped, relative]
        cache.rebuild(for: items, onlyRowsWithMentions: false, resolver: { _ in nil })
        #expect(cache.buildCountForTesting == 3)

        cache.rebuild(for: items, onlyRowsWithMentions: false, resolver: { _ in nil })
        #expect(cache.buildCountForTesting == 3)

        cache.applyTimestampGeneration(1, to: items, resolver: { _ in nil })
        #expect(cache.buildCountForTesting == 5)

        cache.applyTimestampGeneration(1, to: items, resolver: { _ in nil })
        cache.rebuild(for: items, onlyRowsWithMentions: false, resolver: { _ in nil })
        #expect(cache.buildCountForTesting == 5)

        #expect(cache.relativeTimestampSeconds(forRowId: relative.id) == [instant])
        #expect(cache.relativeTimestampSeconds(forRowId: stamped.id).isEmpty)
        cache.refreshRelativeTimestamps(rowIds: [plain.id, stamped.id, relative.id], in: items, resolver: { _ in nil })
        #expect(cache.buildCountForTesting == 6)
    }

    // MARK: - Relative refresh scheduling

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func delay(target offset: TimeInterval, now: Date) -> TimeInterval {
        let target = Int64(now.timeIntervalSince1970 + offset)
        return MarkdownRelativeTimestampSchedule.nextRefreshDate(for: target, now: now, calendar: calendar)
            .timeIntervalSince(now)
    }

    @Test func refreshLandsJustAfterTheDisplayedUnitChanges() {
        // 2026-01-01 12:00:00 UTC, far from midnight.
        let now = Date(timeIntervalSince1970: 1_767_268_800)
        #expect(delay(target: -30, now: now) == 10.5)
        #expect(delay(target: -90, now: now) == 30.5)
        #expect(delay(target: -3_600, now: now) == 3_600.5)
        #expect(delay(target: 45, now: now) == 5.5)
        #expect(delay(target: 125, now: now) == 5.5)
        #expect(delay(target: 3_700, now: now) == 100.5)
        // Exactly on a boundary: the text changes immediately after.
        #expect(delay(target: 3_600, now: now) == MarkdownRelativeTimestampSchedule.minimumDelay)
    }

    @Test func dayScaleInstantsAlsoRefreshAtLocalMidnight() {
        // 2026-01-01 23:30:00 UTC.
        let now = Date(timeIntervalSince1970: 1_767_310_200)
        #expect(delay(target: -2 * 86_400, now: now) == 1_800.5)
        #expect(delay(target: 60 * 86_400 + 3_600, now: now) == 1_800.5)
        // Midday: hourly within a month, daily (via midnight) beyond.
        let noon = Date(timeIntervalSince1970: 1_767_268_800)
        #expect(delay(target: -2 * 86_400, now: noon) == 3_600.5)
        #expect(delay(target: -60 * 86_400, now: noon) == 43_200.5)
    }

    @Test func earliestTargetWinsAndNoTargetsMeansNoRefresh() {
        let now = Date(timeIntervalSince1970: 1_767_268_800)
        let base = Int64(now.timeIntervalSince1970)
        let next = MarkdownRelativeTimestampSchedule.nextRefreshDate(
            for: [base - 3_600, base - 30, base + 3_700],
            now: now,
            calendar: calendar
        )
        #expect(next.map { $0.timeIntervalSince(now) } == 10.5)
        #expect(MarkdownRelativeTimestampSchedule.nextRefreshDate(for: [Int64](), now: now, calendar: calendar) == nil)
    }

    @Test func schedulerRunsOnlyForVisibleRelativeRowsWhileActive() {
        let scheduler = RelativeTimestampRefreshScheduler()
        scheduler.relativeUnixSeconds = { [instant] rowId in rowId == "relative" ? [instant] : [] }

        scheduler.setRowVisible("relative", isVisible: true)
        #expect(!scheduler.isScheduledForTesting)

        scheduler.setActive(true)
        #expect(scheduler.isScheduledForTesting)

        scheduler.setActive(false)
        #expect(!scheduler.isScheduledForTesting)

        scheduler.setRowVisible("relative", isVisible: false)
        scheduler.setRowVisible("absolute", isVisible: true)
        scheduler.setActive(true)
        #expect(!scheduler.isScheduledForTesting)

        scheduler.setRowVisible("relative", isVisible: true)
        #expect(scheduler.isScheduledForTesting)
        scheduler.cancel()
    }

    @Test func trackingKeepsTheRelativeInstantsClosestToTheRenderTime() {
        let now = Date(timeIntervalSince1970: TimeInterval(instant))
        var usage = MarkdownTimestampUsage()
        let farAway = (1...MarkdownTimestampUsage.maxTrackedRelative).map { instant - Int64($0) * 40 * 86_400 }
        for seconds in farAway { usage.record(unixSeconds: seconds, style: .relative, now: now) }
        // The 17th instant is five minutes away and needs the earliest refresh.
        let soon = instant + 300
        usage.record(unixSeconds: soon, style: .relative, now: now)
        #expect(usage.relativeUnixSeconds.count == MarkdownTimestampUsage.maxTrackedRelative)
        #expect(usage.relativeUnixSeconds.contains(soon))
        #expect(!usage.relativeUnixSeconds.contains(farAway.last!))
        // A farther instant never displaces a nearer one.
        usage.record(unixSeconds: instant - 1_000 * 86_400, style: .relative, now: now)
        #expect(!usage.relativeUnixSeconds.contains(instant - 1_000 * 86_400))
        #expect(usage.count == MarkdownTimestampUsage.maxTrackedRelative + 2)
    }

    @Test func aRelativeRowIsRefreshedEachTimeItBecomesVisible() {
        let scheduler = RelativeTimestampRefreshScheduler()
        var refreshed: [Set<String>] = []
        scheduler.relativeUnixSeconds = { [instant] rowId in rowId == "relative" ? [instant] : [] }
        scheduler.refreshRows = { refreshed.append($0) }
        scheduler.setActive(true)

        scheduler.setRowVisible("relative", isVisible: true)
        scheduler.setRowVisible("relative", isVisible: true)
        scheduler.setRowVisible("absolute", isVisible: true)
        #expect(refreshed == [["relative"]])

        // Scrolled away, then back: the text was built for an earlier time.
        scheduler.setRowVisible("relative", isVisible: false)
        scheduler.setRowVisible("relative", isVisible: true)
        #expect(refreshed == [["relative"], ["relative"]])
        scheduler.cancel()
    }

    @Test func formatNotificationsBumpBothGenerationsAndClockOnlyOne() {
        let center = NotificationCenter()
        let clock = MarkdownTimestampRenderClock(notificationCenter: center)
        center.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        center.post(name: .NSSystemTimeZoneDidChange, object: nil)
        #expect(clock.generation == 2)
        #expect(clock.formatGeneration == 2)
        center.post(name: .NSSystemClockDidChange, object: nil)
        clock.invalidate()
        #expect(clock.generation == 4)
        #expect(clock.formatGeneration == 2)
    }
}
