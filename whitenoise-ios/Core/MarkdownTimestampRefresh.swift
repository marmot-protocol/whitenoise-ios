import Foundation
import Observation
import UIKit

/// Render generations for Markdown timestamps. `generation` bumps whenever
/// any rendered instant may read differently: locale or 12/24-hour setting,
/// time zone, in-app language, system clock, significant time change, or app
/// resume. `formatGeneration` bumps only for the first three, which are all
/// that change the absolute text of static one-line previews.
/// Display caches rebuild only the rows that render a timestamp.
@MainActor
@Observable
final class MarkdownTimestampRenderClock {
    private(set) var generation = 0
    private(set) var formatGeneration = 0
    @ObservationIgnored nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let notificationCenter: NotificationCenter

    static let formatNotifications: [Notification.Name] = [
        NSLocale.currentLocaleDidChangeNotification,
        .NSSystemTimeZoneDidChange,
        AppLanguage.didChangeNotification,
    ]

    static let clockNotifications: [Notification.Name] = [
        .NSSystemClockDidChange,
        UIApplication.significantTimeChangeNotification,
    ]

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        let format = Self.formatNotifications.map { name in
            notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.invalidateFormat() }
            }
        }
        let clock = Self.clockNotifications.map { name in
            notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.invalidate() }
            }
        }
        observers = format + clock
    }

    deinit {
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
    }

    /// The clock moved or the app resumed: relative text may differ.
    func invalidate() {
        generation &+= 1
    }

    /// Locale, time zone or language changed: every rendering may differ.
    func invalidateFormat() {
        formatGeneration &+= 1
        generation &+= 1
    }
}

nonisolated enum MarkdownTimestampCachePolicy {
    /// A cached projection is reusable unless it renders a timestamp and was
    /// built under another generation; timestamp-free rows never rebuild.
    static func needsRebuild(
        containsTimestamps: Bool,
        builtGeneration: Int?,
        currentGeneration: Int
    ) -> Bool {
        containsTimestamps && builtGeneration != currentGeneration
    }
}

/// When a visible `relative` timestamp next reads differently.
/// `RelativeDateTimeFormatter` truncates to the largest whole unit, so the
/// text changes just after the distance crosses a multiple of that unit.
/// Far-away instants refresh hourly and at local midnight (for named days
/// such as "tomorrow"), distant ones only at midnight.
nonisolated enum MarkdownRelativeTimestampSchedule {
    /// Lands just past a boundary so the rebuilt text has already changed.
    static let boundaryMargin: TimeInterval = 0.5
    static let minimumDelay: TimeInterval = 1

    static func nextRefreshDate(
        for unixSeconds: some Sequence<Int64>,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        var earliest: Date?
        for seconds in unixSeconds {
            let next = nextRefreshDate(for: seconds, now: now, calendar: calendar)
            if earliest.map({ next < $0 }) ?? true { earliest = next }
        }
        return earliest
    }

    static func nextRefreshDate(for unixSeconds: Int64, now: Date, calendar: Calendar) -> Date {
        let delta = TimeInterval(unixSeconds) - now.timeIntervalSince1970
        let distance = abs(delta)
        // A future instant's distance shrinks: use the unit just below it.
        let step = unitStep(forDistance: delta > 0 ? distance.nextDown : distance)
        let remainder = distance.truncatingRemainder(dividingBy: step)
        var wait = (delta > 0 ? remainder : step - remainder) + boundaryMargin
        if distance >= dayDistance,
           let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) {
            wait = min(wait, midnight.timeIntervalSince(now) + boundaryMargin)
        }
        return now.addingTimeInterval(max(minimumDelay, wait))
    }

    private static let dayDistance: TimeInterval = 86_400

    static func unitStep(forDistance distance: TimeInterval) -> TimeInterval {
        switch distance {
        case ..<60: 10
        case ..<3_600: 60
        case ..<(30 * dayDistance): 3_600
        default: dayDistance
        }
    }
}

/// Re-renders visible conversation rows that show a `relative` timestamp,
/// using one cancellable MainActor task aimed at the earliest next change.
/// Runs only while the conversation is on screen and the app is active.
@MainActor
final class RelativeTimestampRefreshScheduler {
    private var visibleRowIds: Set<String> = []
    private var isActive = false
    private var task: Task<Void, Never>?
    private var scheduledDate: Date?

    /// Relative instants a row renders; empty for rows without any.
    var relativeUnixSeconds: (String) -> [Int64] = { _ in [] }
    /// Rebuilds the given rows' display projections.
    var refreshRows: (Set<String>) -> Void = { _ in }
    var now: () -> Date = Date.init

    var isScheduledForTesting: Bool { task != nil }

    func setRowVisible(_ rowId: String, isVisible: Bool) {
        if isVisible {
            guard visibleRowIds.insert(rowId).inserted,
                  !relativeUnixSeconds(rowId).isEmpty else { return }
            reschedule()
        } else {
            visibleRowIds.remove(rowId)
        }
    }

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        reschedule()
    }

    /// Cheap when nothing changed: keeps an existing task that fires no later
    /// than needed, since an early fire only re-renders and reschedules.
    func reschedule() {
        guard isActive else {
            cancel()
            return
        }
        let seconds = visibleRowIds.flatMap(relativeUnixSeconds)
        guard let next = MarkdownRelativeTimestampSchedule.nextRefreshDate(
            for: seconds,
            now: now(),
            calendar: .autoupdatingCurrent
        ) else {
            cancel()
            return
        }
        if task != nil, let scheduledDate,
           scheduledDate <= next.addingTimeInterval(MarkdownRelativeTimestampSchedule.boundaryMargin) {
            return
        }
        task?.cancel()
        scheduledDate = next
        let delay = max(0, next.timeIntervalSince(now()))
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay), tolerance: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.fire()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        scheduledDate = nil
    }

    private func fire() {
        task = nil
        scheduledDate = nil
        let rows = visibleRowIds.filter { !relativeUnixSeconds($0).isEmpty }
        if !rows.isEmpty {
            refreshRows(rows)
        }
        reschedule()
    }
}
