import Foundation
import MarmotKit

// MARK: - Delivery status (Developer Tools)

@MainActor
protocol AuditDeliveryDataSource: AnyObject {
    var activeAccountRef: String? { get }
    func auditDeliveryStatus() async throws -> [AuditDeliveryStatusV5Ffi]
    func resumeAuditDelivery() async throws
    func present(_ toast: Toast)
}

extension AppState: AuditDeliveryDataSource {
    func auditDeliveryStatus() async throws -> [AuditDeliveryStatusV5Ffi] {
        try await currentMarmotClient().auditDeliveryStatus()
    }

    func resumeAuditDelivery() async throws {
        try await currentMarmotClient().resumeAuditDelivery()
    }
}

/// The active profile's v5 audit delivery state. Reads local files only; only
/// Resume Delivery contacts the receiver.
@MainActor
@Observable
final class AuditDeliveryStatusModel {
    // Avoid the isolated-deinit task-local crash on older Swift runtimes (including iOS 26.2).
    // https://github.com/swiftlang/swift/issues/88036
    nonisolated deinit {}

    /// The active profile's rows, built off the main actor; nil until loaded.
    private(set) var summary: AuditDeliveryPresentation.Summary?
    private(set) var loadFailed = false
    private(set) var isResuming = false

    private var ticket = 0
    private var summaryAccountRef: String?

    func reset() {
        ticket &+= 1
        summary = nil
        summaryAccountRef = nil
        loadFailed = false
    }

    /// Another profile's rows never stay up: they clear when the profile
    /// changes, and a failed read clears them so the error and Retry show.
    func reload(using dataSource: any AuditDeliveryDataSource) async {
        ticket &+= 1
        let current = ticket
        let accountRef = dataSource.activeAccountRef
        if accountRef != summaryAccountRef {
            summary = nil
            summaryAccountRef = accountRef
        }
        do {
            let all = try await dataSource.auditDeliveryStatus()
            guard current == ticket, dataSource.activeAccountRef == accountRef else { return }
            let status = accountRef.flatMap { ref in
                all.first { $0.accountRef.caseInsensitiveCompare(ref) == .orderedSame }
            }
            let locale = AppLanguage.currentLocale
            let built = await Task.detached(priority: .utility) {
                AuditDeliveryPresentation.summary(status, now: Date(), locale: locale)
            }.value
            guard current == ticket, dataSource.activeAccountRef == accountRef else { return }
            summary = built
            loadFailed = false
        } catch is CancellationError {
            return
        } catch {
            guard current == ticket else { return }
            summary = nil
            loadFailed = true
        }
    }

    /// Runs MDK's manual delivery pass, which also lifts a pause, then rereads.
    func resume(using dataSource: any AuditDeliveryDataSource) async {
        guard !isResuming else { return }
        isResuming = true
        defer { isResuming = false }
        do {
            try await dataSource.resumeAuditDelivery()
        } catch is CancellationError {
            return
        } catch {
            dataSource.present(UserFacingError.toast(title: L10n.string("Couldn't resume delivery"), error: error))
        }
        await reload(using: dataSource)
    }
}

nonisolated enum AuditDeliveryPresentation {
    struct Row: Equatable {
        let title: String
        let value: String
    }

    struct Summary: Equatable {
        let rows: [Row]
        /// Resume is offered only while MDK has paused automatic delivery.
        let canResume: Bool
    }

    static func summary(
        _ status: AuditDeliveryStatusV5Ffi?,
        now: Date = Date(),
        locale: Locale = AppLanguage.currentLocale
    ) -> Summary {
        guard let status else {
            return Summary(rows: [Row(title: L10n.string("Status"), value: L10n.string("No delivery record yet"))], canResume: false)
        }
        guard status.destinationConfigured else {
            return Summary(rows: [Row(title: L10n.string("Status"), value: L10n.string("Not configured"))], canResume: false)
        }
        var rows = [
            Row(title: L10n.string("Status"), value: statusText(status)),
            Row(
                title: L10n.string("Last delivered"),
                value: status.lastSuccessAtMs.map { relative(ms: $0, now: now, locale: locale) } ?? L10n.string("Never")
            ),
        ]
        if let failure = status.lastFailure {
            rows.append(Row(
                title: L10n.string("Last failure"),
                value: L10n.formatted("%@, %@", failureText(failure), relative(ms: failure.atMs, now: now, locale: locale))
            ))
        }
        if status.consecutiveFailures > 0 {
            rows.append(Row(title: L10n.string("Failures in a row"), value: number(status.consecutiveFailures, locale)))
        }
        if status.rejectedBatches > 0 {
            rows.append(Row(title: L10n.string("Skipped batches"), value: number(status.rejectedBatches, locale)))
        }
        if let backlog = status.backlog, backlog.undeliveredBytes > 0 {
            rows.append(Row(
                title: L10n.string("Waiting to upload"),
                value: ByteCountFormatter.string(fromByteCount: Int64(clamping: backlog.undeliveredBytes), countStyle: .file)
            ))
            if let oldest = backlog.oldestUndeliveredAtMs {
                rows.append(Row(title: L10n.string("Oldest waiting"), value: relative(ms: oldest, now: now, locale: locale)))
            }
        }
        if let gaps = status.backlog?.gaps, gaps > 0 {
            rows.append(Row(title: L10n.string("Missing ranges"), value: number(gaps, locale)))
        }
        return Summary(rows: rows, canResume: status.paused)
    }

    static func statusText(_ status: AuditDeliveryStatusV5Ffi) -> String {
        if status.paused { return L10n.string("Paused") }
        if status.consecutiveFailures > 0 { return L10n.string("Retrying") }
        return L10n.string("Active")
    }

    static func failureText(_ failure: AuditDeliveryFailureV5Ffi) -> String {
        let kind: String = switch failure.kind {
        case .stateOverLimit: L10n.string("Delivery record too large")
        case .tooManyOpenFiles: L10n.string("Too many open files")
        case .localIo: L10n.string("Local file error")
        case .localBlocked: L10n.string("Local log blocked")
        case .receiverBlocked: L10n.string("Receiver refused this configuration")
        case .receiverRejected: L10n.string("Receiver rejected some records")
        case .receiverRetryable: L10n.string("Receiver busy or unavailable")
        case .noResponse: L10n.string("No response")
        case .internal: L10n.string("Internal error")
        }
        guard let http = failure.httpStatus else { return kind }
        return L10n.formatted("%1$@ (HTTP %2$lld)", kind, Int64(http))
    }

    private static func number(_ value: UInt64, _ locale: Locale) -> String {
        Int64(clamping: value).formatted(.number.locale(locale))
    }

    private static func relative(ms: UInt64, now: Date, locale: Locale) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(Int64(clamping: ms / 1_000)))
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }
}

// MARK: - Retention (Diagnostics & Improvements)

@MainActor
protocol AuditLogRetentionDataSource: AnyObject {
    func auditLogRetention() async throws -> AuditLogRetentionFfi
    func setAuditLogRetention(_ retention: AuditLogRetentionFfi) async throws -> AuditLogRetentionFfi
    func present(_ toast: Toast)
}

extension AppState: AuditLogRetentionDataSource {
    func auditLogRetention() async throws -> AuditLogRetentionFfi {
        try await currentMarmotClient().auditLogRetention()
    }

    func setAuditLogRetention(_ retention: AuditLogRetentionFfi) async throws -> AuditLogRetentionFfi {
        try await currentMarmotClient().setAuditLogRetention(retention)
    }
}

/// How long this device keeps diagnostic logs. MDK stores one device-wide
/// policy and returns the clamped value it saved; only the age is offered,
/// and the per-profile size budget is kept as stored.
@MainActor
@Observable
final class AuditLogRetentionModel {
    // Avoid the isolated-deinit task-local crash on older Swift runtimes (including iOS 26.2).
    // https://github.com/swiftlang/swift/issues/88036
    nonisolated deinit {}

    private(set) var retention: AuditLogRetentionFfi?
    private(set) var loadFailed = false
    private(set) var isSaving = false
    /// A shorter period waiting for the user to confirm deleting older logs.
    var pendingShorterDays: UInt32?
    /// Bumped by every save, so a read that started before it can't put the
    /// old period back on screen.
    private var saveGeneration = 0

    func load(using dataSource: any AuditLogRetentionDataSource) async {
        let generation = saveGeneration
        do {
            let loaded = try await dataSource.auditLogRetention()
            guard generation == saveGeneration else { return }
            retention = loaded
            loadFailed = false
        } catch is CancellationError {
            return
        } catch {
            guard generation == saveGeneration else { return }
            loadFailed = true
        }
    }

    /// A longer period applies at once; a shorter one deletes logs, so it
    /// waits in `pendingShorterDays` for confirmation.
    func choose(days: UInt32, using dataSource: any AuditLogRetentionDataSource) async {
        guard let current = retention, days != current.maxAgeDays else { return }
        if days < current.maxAgeDays {
            pendingShorterDays = days
            return
        }
        await save(days: days, using: dataSource)
    }

    /// `days` comes from the alert that presented it: dismissing the alert
    /// clears `pendingShorterDays` before the button's task runs. Returns
    /// whether the shorter period was saved, so the caller can refresh what
    /// the deletion changed.
    @discardableResult
    func confirmShorter(days: UInt32, using dataSource: any AuditLogRetentionDataSource) async -> Bool {
        pendingShorterDays = nil
        return await save(days: days, using: dataSource)
    }

    @discardableResult
    private func save(days: UInt32, using dataSource: any AuditLogRetentionDataSource) async -> Bool {
        guard let current = retention, !isSaving else { return false }
        saveGeneration &+= 1
        isSaving = true
        defer { isSaving = false }
        do {
            retention = try await dataSource.setAuditLogRetention(
                AuditLogRetentionFfi(maxAgeDays: days, maxBytesPerAccount: current.maxBytesPerAccount)
            )
            return true
        } catch is CancellationError {
            return false
        } catch {
            dataSource.present(UserFacingError.toast(
                title: L10n.string("Couldn't change how long logs are kept"),
                error: error
            ))
            return false
        }
    }
}

nonisolated enum AuditLogRetentionPresentation {
    /// MDK clamps the age to 1–30 days.
    static let dayRange: ClosedRange<UInt32> = 1...30
    static let standardDays: [UInt32] = [1, 3, 7, 14, 30]

    /// The standard choices plus the stored value, so a value set elsewhere
    /// still shows as selected.
    static func options(including current: UInt32) -> [UInt32] {
        let clamped = min(max(current, dayRange.lowerBound), dayRange.upperBound)
        return Array(Set(standardDays + [clamped])).sorted()
    }

    /// Logs last modified before this (Unix milliseconds) are past `days`.
    static func cutoffMs(days: UInt32, now: Date = Date()) -> UInt64 {
        let cutoff = now.timeIntervalSince1970 - TimeInterval(days) * 86_400
        return UInt64(max(0, cutoff * 1_000))
    }

    static func title(days: UInt32) -> String {
        L10n.plural("%lld days", Int64(days))
    }
}
