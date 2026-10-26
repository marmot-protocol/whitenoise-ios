import Foundation
import MarmotKit

enum ManageStoragePresentation {
    /// MDK accepts 1...256 per page.
    static let pageLimit: UInt32 = 50

    struct Usage: Equatable {
        let attachmentBytes: UInt64
        let attachmentCount: UInt64
        /// The account database's live data, without its free pages or the
        /// attachment bodies still inside it.
        let chatDataBytes: UInt64
        /// Free pages the database file still holds. iOS counts them until the
        /// database is compacted, so they stay on screen rather than vanish.
        let unusedDatabaseBytes: UInt64
        let cacheBytes: UInt64
        let migration: MigrationNotice?

        init(_ usage: AttachmentStorageUsageFfi) {
            attachmentBytes = saturatingSum(usage.mediaBytes, usage.legacyBytes)
            attachmentCount = usage.attachmentCount
            chatDataBytes = saturatingDifference(saturatingDifference(usage.databaseBytes, usage.databaseFreeBytes),
                                                 usage.legacyBytes)
            unusedDatabaseBytes = usage.databaseFreeBytes
            cacheBytes = usage.cacheBytes
            migration = migrationNotice(usage.migration, bytes: usage.migrationBytes)
        }
    }

    enum MigrationNotice: Equatable {
        case moving(remainingBytes: UInt64)
        /// The move resumes once this many more bytes are free.
        case paused(neededBytes: UInt64)
        case compacting
    }

    static func migrationNotice(_ state: AttachmentMigrationStateFfi, bytes: UInt64) -> MigrationNotice? {
        switch state {
        case .notNeeded, .complete: nil
        case .running: .moving(remainingBytes: bytes)
        case .paused: .paused(neededBytes: bytes)
        case .compacting: .compacting
        }
    }

    /// Usage has no observer, so re-read it while it can still change on its own.
    /// MDK moves a batch, or rechecks free space for a paused move, every 15
    /// seconds; compaction typically ends within a second.
    static func usageRefreshDelay(for notice: MigrationNotice?) -> Duration? {
        switch notice {
        case .moving, .paused: .seconds(15)
        case .compacting: .seconds(2)
        case nil: nil
        }
    }

    /// The figures on screen and whether the latest read of them failed. Every
    /// read, failed or not, advances `revision` so a running poll reschedules.
    struct UsageRefresh: Equatable {
        private(set) var usage: Usage?
        private(set) var failed = false
        private(set) var revision = 0

        /// Keeps polling stale figures while they were still changing on their own.
        var nextDelay: Duration? { ManageStoragePresentation.usageRefreshDelay(for: usage?.migration) }

        mutating func succeeded(_ usage: Usage) {
            self.usage = usage
            failed = false
            revision &+= 1
        }

        mutating func failedToRefresh() {
            failed = true
            revision &+= 1
        }
    }

    static func byteText(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    enum RemovalAge: CaseIterable, Hashable {
        case oneWeek, oneMonth, threeMonths, sixMonths, oneYear

        var title: String {
            switch self {
            case .oneWeek: L10n.string("Older Than 1 Week")
            case .oneMonth: L10n.string("Older Than 1 Month")
            case .threeMonths: L10n.string("Older Than 3 Months")
            case .sixMonths: L10n.string("Older Than 6 Months")
            case .oneYear: L10n.string("Older Than 1 Year")
            }
        }

        /// The start of the day the confirmation names, so nothing received on it goes.
        func cutoffDate(now: Date, calendar: Calendar) -> Date {
            let (component, value): (Calendar.Component, Int) = switch self {
            case .oneWeek: (.day, -7)
            case .oneMonth: (.month, -1)
            case .threeMonths: (.month, -3)
            case .sixMonths: (.month, -6)
            case .oneYear: (.year, -1)
            }
            return calendar.startOfDay(for: calendar.date(byAdding: component, value: value, to: now) ?? now)
        }
    }

    /// Captured once when an age is chosen; the confirmation names this day and
    /// the removal uses this instant, however long the dialog stays up.
    struct RemovalCutoff: Equatable {
        let age: RemovalAge
        let date: Date
        let calendar: Calendar

        init(age: RemovalAge, now: Date, calendar: Calendar) {
            self.age = age
            self.calendar = calendar
            date = age.cutoffDate(now: now, calendar: calendar)
        }

        /// `removeAttachmentsOlderThan` removes messages received strictly before these Unix seconds.
        var receivedBefore: UInt64 {
            let seconds = date.timeIntervalSince1970.rounded(.down)
            return seconds > 0 ? UInt64(seconds) : 0
        }

        func text(locale: Locale = AppLanguage.currentLocale) -> String {
            date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
                .year().month(.wide).day())
        }
    }

    /// MDK's "Keep media" windows, longest first. Only a shorter window removes
    /// anything, so only that asks first. MDK can't count what it will remove:
    /// it removes and counts in one call, and a later download restarts an
    /// attachment's age, which the app can't see.
    enum KeepMedia {
        static let options: [AttachmentKeepMediaFfi] = [.forever, .oneYear, .sixMonths, .thirtyDays]

        struct Confirmation: Equatable {
            let keep: AttachmentKeepMediaFfi
            let title: String
            let message: String
            let action: String
        }

        /// The window MDK has saved, as far as this screen knows. Shorter windows
        /// confirm against it, so it never holds a value that may be stale.
        struct Refresh: Equatable {
            private(set) var keep: AttachmentKeepMediaFfi?
            private(set) var failed = false

            mutating func succeeded(_ keep: AttachmentKeepMediaFfi) {
                self.keep = keep
                failed = false
            }

            /// Only a change from this screen moves the window, so the last known one stands.
            mutating func failedToRefresh() {
                failed = true
            }

            /// A failed change may have saved either window, so it stays unknown until read again.
            mutating func changed(to keep: AttachmentKeepMediaFfi, saved: Bool) {
                self.keep = saved ? keep : nil
            }
        }

        static func title(_ keep: AttachmentKeepMediaFfi) -> String {
            switch keep {
            case .forever: L10n.string("Forever")
            case .oneYear: L10n.string("1 Year")
            case .sixMonths: L10n.string("6 Months")
            case .thirtyDays: L10n.string("30 Days")
            }
        }

        /// The window MDK applies, in days; nil keeps everything.
        static func days(_ keep: AttachmentKeepMediaFfi) -> Int? {
            switch keep {
            case .forever: nil
            case .oneYear: 365
            case .sixMonths: 183
            case .thirtyDays: 30
            }
        }

        static func confirmation(from current: AttachmentKeepMediaFfi,
                                 to next: AttachmentKeepMediaFfi) -> Confirmation? {
            guard let nextDays = days(next) else { return nil }
            if let currentDays = days(current), currentDays <= nextDays { return nil }
            return switch next {
            case .forever: nil
            case .oneYear: Confirmation(
                keep: next, title: L10n.string("Keep Media for 1 Year?"),
                message: L10n.string("Attachments older than 1 year are removed from this device now and as they age. Messages stay, and you can download attachments again while they're still available."),
                action: L10n.string("Keep for 1 Year"))
            case .sixMonths: Confirmation(
                keep: next, title: L10n.string("Keep Media for 6 Months?"),
                message: L10n.string("Attachments older than 6 months are removed from this device now and as they age. Messages stay, and you can download attachments again while they're still available."),
                action: L10n.string("Keep for 6 Months"))
            case .thirtyDays: Confirmation(
                keep: next, title: L10n.string("Keep Media for 30 Days?"),
                message: L10n.string("Attachments older than 30 days are removed from this device now and as they age. Messages stay, and you can download attachments again while they're still available."),
                action: L10n.string("Keep for 30 Days"))
            }
        }

        /// Reports MDK's count once it has removed them. A longer window says
        /// nothing unless it removed something.
        static func resultText(removed: UInt64, confirmed: Bool) -> String? {
            if removed > 0 { return L10n.plural("Removed %lld attachments", removed) }
            return confirmed ? L10n.string("No attachments were old enough to remove.") : nil
        }
    }

    /// Stable across pages and removals: the original message and slot.
    static func attachmentID(_ attachment: RetainedAttachmentSummaryFfi) -> String {
        let target = attachment.target
        return [attachment.groupIdHex, target.messageIdHex, target.sourceMessageIdHex,
                String(target.attachmentIndex)].joined(separator: ":")
    }

    static func attachmentKind(_ attachment: RetainedAttachmentSummaryFfi) -> MediaAttachmentKind {
        MediaAttachmentKind.classify(mediaType: attachment.mediaType, fileName: attachment.fileName)
    }

    /// File names are peer-controlled; fall back to the kind when one is blank.
    static func attachmentTitle(_ attachment: RetainedAttachmentSummaryFfi) -> String {
        if let name = ContentSanitizer.compactSingleLine(attachment.fileName,
                                                         maxLength: MessageSemantics.maxImetaFileNameBytes) {
            return name
        }
        return switch attachmentKind(attachment) {
        case .image: L10n.string("Photo")
        case .video: L10n.string("Video")
        case .audio: L10n.string("Audio")
        case .document, .unsupported: L10n.string("Attachment")
        }
    }

    /// The chat's name leads only in the account-wide list.
    static func attachmentSubtitle(_ attachment: RetainedAttachmentSummaryFfi, chatTitle: String?,
                                   now: Date = Date(), locale: Locale = AppLanguage.currentLocale) -> String {
        let received = attachment.receivedAt > 0
            ? RelativeTime.short(Date(timeIntervalSince1970: TimeInterval(attachment.receivedAt)), now: now,
                                 locale: locale)
            : nil
        switch (chatTitle, received) {
        case let (chat?, received?):
            return L10n.formatted("%@ · %@", arguments: [chat, received], locale: locale)
        case let (chat?, nil): return chat
        case let (nil, received?): return received
        case (nil, nil): return ""
        }
    }

    private static func saturatingSum(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }

    private static func saturatingDifference(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        lhs >= rhs ? lhs - rhs : 0
    }
}

/// Largest-first pages behind an opaque cursor. Cursors are never persisted,
/// and any removal starts the listing over.
struct StoragePageList<Item, Cursor> {
    private(set) var items: [Item] = []
    private(set) var cursor: Cursor?
    /// Advances on every page, including an empty one, so a visible
    /// load-more row can ask again.
    private(set) var pageCount = 0
    private var ids: Set<String> = []
    private let id: (Item) -> String

    init(id: @escaping (Item) -> String) {
        self.id = id
    }

    var hasMore: Bool { pageCount == 0 || cursor != nil }

    mutating func append(_ page: [Item], next: Cursor?) {
        for item in page where ids.insert(id(item)).inserted {
            items.append(item)
        }
        cursor = next
        pageCount += 1
    }
}
