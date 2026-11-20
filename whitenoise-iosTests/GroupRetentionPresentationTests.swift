import Foundation
import Testing
@testable import whitenoise_ios

struct GroupRetentionPresentationTests {

    @Test func presetTableIsOffPlusStandardTimers() {
        let expected: [UInt64] = [
            0,
            30,
            5 * 60,
            60 * 60,
            8 * 60 * 60,
            24 * 60 * 60,
            7 * 24 * 60 * 60,
            30 * 24 * 60 * 60,
        ]
        #expect(GroupRetentionPresentation.presetSeconds == expected)
    }

    @Test func confirmationRequiredWhenEnablingTimer() {
        #expect(GroupRetentionPresentation.requiresRetroactivePruneConfirmation(
            currentSeconds: 0,
            newSeconds: 30
        ))
        #expect(GroupRetentionPresentation.requiresRetroactivePruneConfirmation(
            currentSeconds: 0,
            newSeconds: 30 * 24 * 60 * 60
        ))
    }

    @Test func confirmationRequiredWhenShorteningTimer() {
        #expect(GroupRetentionPresentation.requiresRetroactivePruneConfirmation(
            currentSeconds: 3_600,
            newSeconds: 30
        ))
        #expect(GroupRetentionPresentation.requiresRetroactivePruneConfirmation(
            currentSeconds: 3_600,
            newSeconds: 3_599
        ))
    }

    @Test func noConfirmationWhenTurningOffLengtheningOrUnchanged() {
        #expect(!GroupRetentionPresentation.requiresRetroactivePruneConfirmation(
            currentSeconds: 3_600,
            newSeconds: 0
        ))
        #expect(!GroupRetentionPresentation.requiresRetroactivePruneConfirmation(
            currentSeconds: 0,
            newSeconds: 0
        ))
        #expect(!GroupRetentionPresentation.requiresRetroactivePruneConfirmation(
            currentSeconds: 3_600,
            newSeconds: 24 * 60 * 60
        ))
        #expect(!GroupRetentionPresentation.requiresRetroactivePruneConfirmation(
            currentSeconds: 3_600,
            newSeconds: 3_600
        ))
    }

    @Test func customSecondsMultipliesByUnit() {
        #expect(GroupRetentionPresentation.customSeconds(value: "45", unit: .seconds) == 45)
        #expect(GroupRetentionPresentation.customSeconds(value: "5", unit: .minutes) == 300)
        #expect(GroupRetentionPresentation.customSeconds(value: "2", unit: .hours) == 7_200)
        #expect(GroupRetentionPresentation.customSeconds(value: "3", unit: .days) == 259_200)
        #expect(GroupRetentionPresentation.customSeconds(value: "2", unit: .weeks) == 1_209_600)
        #expect(GroupRetentionPresentation.customSeconds(value: " 45 ", unit: .seconds) == 45)
    }

    @Test func customSecondsRejectsInvalidInput() {
        #expect(GroupRetentionPresentation.customSeconds(value: "", unit: .minutes) == nil)
        #expect(GroupRetentionPresentation.customSeconds(value: "abc", unit: .minutes) == nil)
        #expect(GroupRetentionPresentation.customSeconds(value: "0", unit: .minutes) == nil)
        #expect(GroupRetentionPresentation.customSeconds(value: "-5", unit: .minutes) == nil)
        #expect(GroupRetentionPresentation.customSeconds(value: "1.5", unit: .hours) == nil)
    }

    @Test func customSecondsEnforcesBounds() {
        #expect(GroupRetentionPresentation.customSeconds(value: "29", unit: .seconds) == nil)
        #expect(GroupRetentionPresentation.customSeconds(value: "30", unit: .seconds) == 30)
        #expect(GroupRetentionPresentation.customSeconds(value: "365", unit: .days) == 31_536_000)
        #expect(GroupRetentionPresentation.customSeconds(value: "366", unit: .days) == nil)
        #expect(GroupRetentionPresentation.customSeconds(value: "53", unit: .weeks) == nil)
        // Overflow-sized input must fail parsing, not trap.
        #expect(GroupRetentionPresentation.customSeconds(
            value: "99999999999999999999",
            unit: .weeks
        ) == nil)
        #expect(GroupRetentionPresentation.customSeconds(
            value: String(UInt64.max),
            unit: .weeks
        ) == nil)
    }

    @Test func customDraftPrefersLargestEvenUnit() {
        #expect(GroupRetentionPresentation.customDraft(forSeconds: 45) == ("45", .seconds))
        #expect(GroupRetentionPresentation.customDraft(forSeconds: 300) == ("5", .minutes))
        #expect(GroupRetentionPresentation.customDraft(forSeconds: 5 * 60 * 60) == ("5", .hours))
        #expect(GroupRetentionPresentation.customDraft(forSeconds: 3 * 24 * 60 * 60) == ("3", .days))
        #expect(GroupRetentionPresentation.customDraft(forSeconds: 2 * 7 * 24 * 60 * 60) == ("2", .weeks))
        #expect(GroupRetentionPresentation.customDraft(forSeconds: 90) == ("90", .seconds))
    }

    @Test func customDraftForOffTimerIsEmpty() {
        let draft = GroupRetentionPresentation.customDraft(forSeconds: 0)
        #expect(draft.value.isEmpty)
    }

    @Test func headerDurationUsesCompactDaysWeeksAndRoundedCustomIntervals() {
        let locale = Locale(identifier: "en_US")
        #expect(GroupRetentionPresentation.compactLabel(seconds: 86_400, locale: locale) == "1d")
        #expect(GroupRetentionPresentation.compactLabel(seconds: 28 * 86_400, locale: locale) == "4w")
        #expect(GroupRetentionPresentation.compactLabel(seconds: 100_000, locale: locale) == "1d 4h")
    }

    @Test func labelUsesOffSentinelForZero() {
        let offLabel = GroupRetentionPresentation.label(seconds: 0)
        #expect(offLabel == L10n.string("Off"))
        #expect(GroupRetentionPresentation.label(seconds: 300) != offLabel)
        #expect(!GroupRetentionPresentation.label(seconds: 300).isEmpty)
    }

    @Test func durationDoesNotGainAnHourWhenItCrossesDaylightSavingTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Rome")!

        let label = GroupSystemEventPresentation.retentionDurationText(
            seconds: 90 * 24 * 60 * 60,
            locale: Locale(identifier: "en_US"),
            calendar: calendar
        )

        #expect(label == "90 days")
    }
}
