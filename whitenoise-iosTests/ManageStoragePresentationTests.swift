import Foundation
import Testing
import MarmotKit
@testable import whitenoise_ios

@MainActor
struct ManageStoragePresentationTests {
    private static func usage(media: UInt64 = 0, legacy: UInt64 = 0, count: UInt64 = 0,
                              database: UInt64 = 0, databaseFree: UInt64 = 0,
                              migration: AttachmentMigrationStateFfi = .notNeeded,
                              migrationBytes: UInt64 = 0, cache: UInt64 = 0) -> AttachmentStorageUsageFfi {
        AttachmentStorageUsageFfi(mediaBytes: media, legacyBytes: legacy, attachmentCount: count,
                                  databaseBytes: database, databaseFreeBytes: databaseFree,
                                  migration: migration, migrationBytes: migrationBytes, cacheBytes: cache)
    }

    private static func attachment(group: String = "g1", message: String = "m1", source: String = "s1",
                                   index: UInt32 = 0, bytes: UInt64 = 1_024, mediaType: String = "image/jpeg",
                                   fileName: String = "beach.jpg", receivedAt: UInt64 = 0) -> RetainedAttachmentSummaryFfi {
        RetainedAttachmentSummaryFfi(
            groupIdHex: group,
            target: AttachmentLocalTargetFfi(messageIdHex: message, sourceMessageIdHex: source, attachmentIndex: index),
            byteCount: bytes, mediaType: mediaType, fileName: fileName, receivedAt: receivedAt
        )
    }

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    // MARK: Usage

    /// Attachments live in both layouts until the background move finishes, so
    /// both count as attachments; the legacy part is not counted again as chat data.
    @Test func attachmentsCountBothLayoutsAndChatDataExcludesLegacyBodies() {
        let usage = ManageStoragePresentation.Usage(Self.usage(media: 700, legacy: 300, count: 12,
                                                               database: 1_000, cache: 50))
        #expect(usage.attachmentBytes == 1_000)
        #expect(usage.attachmentCount == 12)
        #expect(usage.chatDataBytes == 700)
        #expect(usage.cacheBytes == 50)
    }

    @Test func figuresNeverWrapAround() {
        let usage = ManageStoragePresentation.Usage(Self.usage(media: .max, legacy: 10, database: 5))
        #expect(usage.attachmentBytes == .max)
        #expect(usage.chatDataBytes == 0)
    }

    @Test func onlyUnfinishedMigrationStatesShowANotice() {
        #expect(ManageStoragePresentation.migrationNotice(.notNeeded, bytes: 0) == nil)
        #expect(ManageStoragePresentation.migrationNotice(.complete, bytes: 0) == nil)
        #expect(ManageStoragePresentation.migrationNotice(.running, bytes: 4_096) == .moving(remainingBytes: 4_096))
        #expect(ManageStoragePresentation.migrationNotice(.paused, bytes: 9_000) == .paused(neededBytes: 9_000))
        #expect(ManageStoragePresentation.migrationNotice(.compacting, bytes: 0) == .compacting)
        #expect(ManageStoragePresentation.Usage(Self.usage(migration: .paused, migrationBytes: 77)).migration
            == .paused(neededBytes: 77))
    }

    /// MDK rechecks free space for a paused move on its 15-second tick, so a
    /// paused move can resume without anything happening on this screen.
    @Test func usageIsReReadWhileItCanChangeOnItsOwn() {
        #expect(ManageStoragePresentation.usageRefreshDelay(for: .moving(remainingBytes: 1)) == .seconds(15))
        #expect(ManageStoragePresentation.usageRefreshDelay(for: .paused(neededBytes: 1)) == .seconds(15))
        #expect(ManageStoragePresentation.usageRefreshDelay(for: .compacting) == .seconds(2))
        #expect(ManageStoragePresentation.usageRefreshDelay(for: nil) == nil)
    }

    @Test func pausedMoveKeepsPollingUntilItResumesAndFinishes() {
        var refresh = ManageStoragePresentation.UsageRefresh()
        #expect(refresh.nextDelay == nil)

        refresh.succeeded(.init(Self.usage(migration: .paused, migrationBytes: 9_000)))
        #expect(refresh.usage?.migration == .paused(neededBytes: 9_000))
        #expect(refresh.nextDelay == .seconds(15))

        refresh.succeeded(.init(Self.usage(migration: .running, migrationBytes: 4_000)))
        #expect(refresh.usage?.migration == .moving(remainingBytes: 4_000))
        #expect(refresh.nextDelay == .seconds(15))

        refresh.succeeded(.init(Self.usage(migration: .complete)))
        #expect(refresh.usage?.migration == nil)
        #expect(refresh.nextDelay == nil)
    }

    /// A failed read keeps the last figures but says so, and the poll goes on
    /// because those figures were still changing.
    @Test func failedRefreshKeepsPollingAndIsShownUntilAReadSucceeds() {
        var refresh = ManageStoragePresentation.UsageRefresh()
        refresh.succeeded(.init(Self.usage(media: 10, migration: .running, migrationBytes: 4_000)))
        let revision = refresh.revision

        refresh.failedToRefresh()
        #expect(refresh.failed)
        #expect(refresh.revision != revision)
        #expect(refresh.usage?.attachmentBytes == 10)
        #expect(refresh.nextDelay == .seconds(15))

        refresh.failedToRefresh()
        refresh.succeeded(.init(Self.usage(media: 10, migration: .compacting)))
        #expect(!refresh.failed)
        #expect(refresh.nextDelay == .seconds(2))
    }

    @Test func failedFirstReadHasNothingToPoll() {
        var refresh = ManageStoragePresentation.UsageRefresh()
        refresh.failedToRefresh()
        #expect(refresh.failed)
        #expect(refresh.usage == nil)
        #expect(refresh.nextDelay == nil)
    }

    // MARK: Removal ages

    private static var losAngeles: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    private static func midnight(_ year: Int, _ month: Int, _ day: Int, in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    /// Cutoffs start the named day, so attachments received on it stay.
    @Test func removalCutoffsStartTheNamedDay() {
        let calendar = Self.losAngeles
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 31, hour: 21, minute: 30))!
        typealias Age = ManageStoragePresentation.RemovalAge
        #expect(Age.oneWeek.cutoffDate(now: now, calendar: calendar) == Self.midnight(2026, 3, 24, in: calendar))
        #expect(Age.oneMonth.cutoffDate(now: now, calendar: calendar) == Self.midnight(2026, 2, 28, in: calendar))
        #expect(Age.threeMonths.cutoffDate(now: now, calendar: calendar) == Self.midnight(2025, 12, 31, in: calendar))
        #expect(Age.sixMonths.cutoffDate(now: now, calendar: calendar) == Self.midnight(2025, 9, 30, in: calendar))
        #expect(Age.oneYear.cutoffDate(now: now, calendar: calendar) == Self.midnight(2025, 3, 31, in: calendar))
    }

    /// The confirmation's day and the instant passed to MDK come from one capture,
    /// late in the evening and across a daylight-saving change alike.
    @Test func capturedCutoffNamesTheInstantItRemovesBefore() {
        let calendar = Self.losAngeles
        let locale = Locale(identifier: "en_US")
        let lateEvening = calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 23, minute: 59))!
        let cutoff = ManageStoragePresentation.RemovalCutoff(age: .oneWeek, now: lateEvening, calendar: calendar)
        #expect(cutoff.text(locale: locale) == "October 15, 2026")
        #expect(cutoff.receivedBefore == UInt64(Self.midnight(2026, 10, 15, in: calendar).timeIntervalSince1970))

        let afterSpringForward = calendar.date(from: DateComponents(year: 2026, month: 3, day: 12, hour: 21))!
        let acrossChange = ManageStoragePresentation.RemovalCutoff(age: .oneWeek, now: afterSpringForward,
                                                                   calendar: calendar)
        #expect(acrossChange.text(locale: locale) == "March 5, 2026")
        let removedBefore = Date(timeIntervalSince1970: TimeInterval(acrossChange.receivedBefore))
        #expect(calendar.dateComponents([.year, .month, .day, .hour, .minute], from: removedBefore)
            == DateComponents(year: 2026, month: 3, day: 5, hour: 0, minute: 0))
    }

    @Test func receivedBeforeIsNeverNegative() {
        let cutoff = ManageStoragePresentation.RemovalCutoff(age: .oneYear, now: Date(timeIntervalSince1970: 0),
                                                             calendar: Self.utc)
        #expect(cutoff.receivedBefore == 0)
    }

    @Test func everyAgeHasItsOwnTitle() {
        let titles = ManageStoragePresentation.RemovalAge.allCases.map(\.title)
        #expect(Set(titles).count == titles.count)
        #expect(titles.allSatisfy { !$0.isEmpty })
    }

    // MARK: Attachment rows

    /// Identity follows the original message and slot, so pages and removals
    /// never collapse two attachments of one message.
    @Test func attachmentIDKeepsMessageAndSlotIdentity() {
        let first = ManageStoragePresentation.attachmentID(Self.attachment(index: 0))
        let second = ManageStoragePresentation.attachmentID(Self.attachment(index: 1))
        let otherSource = ManageStoragePresentation.attachmentID(Self.attachment(source: "s2"))
        let otherChat = ManageStoragePresentation.attachmentID(Self.attachment(group: "g2"))
        #expect(Set([first, second, otherSource, otherChat]).count == 4)
        #expect(first == ManageStoragePresentation.attachmentID(Self.attachment(bytes: 99, fileName: "renamed.jpg")))
    }

    @Test func titleSanitizesPeerFileNames() {
        let title = ManageStoragePresentation.attachmentTitle(Self.attachment(fileName: "  trip\n\u{202E}gpj.exe  "))
        #expect(!title.contains("\n"))
        #expect(!title.contains("\u{202E}"))
        #expect(title.hasPrefix("trip"))
    }

    @Test func blankFileNamesFallBackToTheKind() {
        #expect(ManageStoragePresentation.attachmentTitle(Self.attachment(mediaType: "image/png", fileName: " "))
            == L10n.string("Photo"))
        #expect(ManageStoragePresentation.attachmentTitle(Self.attachment(mediaType: "video/mp4", fileName: ""))
            == L10n.string("Video"))
        #expect(ManageStoragePresentation.attachmentTitle(Self.attachment(mediaType: "audio/mp4", fileName: ""))
            == L10n.string("Audio"))
        #expect(ManageStoragePresentation.attachmentTitle(Self.attachment(mediaType: "", fileName: ""))
            == L10n.string("Attachment"))
    }

    @Test func subtitleLeadsWithTheChatOnlyWhenGiven() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let locale = Locale(identifier: "en_US")
        let received = Self.attachment(receivedAt: 1_800_000_000 - 3 * 86_400)
        let dateOnly = ManageStoragePresentation.attachmentSubtitle(received, chatTitle: nil, now: now, locale: locale)
        #expect(!dateOnly.isEmpty)
        #expect(ManageStoragePresentation.attachmentSubtitle(received, chatTitle: "Hiking", now: now, locale: locale)
            == "Hiking · \(dateOnly)")
        #expect(ManageStoragePresentation.attachmentSubtitle(Self.attachment(receivedAt: 0), chatTitle: "Hiking",
                                                             now: now, locale: locale) == "Hiking")
        #expect(ManageStoragePresentation.attachmentSubtitle(Self.attachment(receivedAt: 0), chatTitle: nil,
                                                             now: now, locale: locale).isEmpty)
    }

    // MARK: Paging

    @Test func pageListAsksForTheFirstPageThenFollowsTheCursor() {
        var list = StoragePageList<String, Int>(id: { $0 })
        #expect(list.hasMore)
        #expect(list.cursor == nil)

        list.append(["a", "b"], next: 1)
        #expect(list.items == ["a", "b"])
        #expect(list.cursor == 1)
        #expect(list.hasMore)

        list.append(["c"], next: nil)
        #expect(list.items == ["a", "b", "c"])
        #expect(!list.hasMore)
    }

    /// MDK may end with an empty page; it still counts so a visible load-more
    /// row asks again or stops.
    @Test func emptyPagesAdvanceAndEndTheListing() {
        var list = StoragePageList<String, Int>(id: { $0 })
        list.append(["a"], next: 1)
        list.append([], next: 2)
        #expect(list.pageCount == 2)
        #expect(list.hasMore)
        list.append([], next: nil)
        #expect(list.pageCount == 3)
        #expect(!list.hasMore)
        #expect(list.items == ["a"])
    }

    @Test func pageListKeepsTheFirstCopyOfARepeatedItem() {
        var list = StoragePageList<(id: String, size: Int), Int>(id: { $0.id })
        list.append([("a", 3), ("b", 2)], next: 1)
        list.append([("b", 1), ("c", 1)], next: nil)
        #expect(list.items.map(\.id) == ["a", "b", "c"])
        #expect(list.items[1].size == 2)
    }
}
