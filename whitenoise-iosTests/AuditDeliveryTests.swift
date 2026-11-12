import Foundation
import MarmotKit
import Testing
@testable import whitenoise_ios

@MainActor
struct AuditDeliveryTests {
    private let active = String(repeating: "ab", count: 32)
    private let other = String(repeating: "cd", count: 32)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Delivery status presentation

    @Test func anUnconfiguredOrMissingDestinationShowsOnlyItsStatus() {
        for status in [nil, status(configured: false)] {
            let summary = AuditDeliveryPresentation.summary(status, now: now)
            #expect(summary.rows.count == 1)
            #expect(!summary.canResume)
        }
    }

    @Test func onlyAPausedDeliveryOffersResume() {
        let paused = AuditDeliveryPresentation.summary(status(paused: true, failures: 3), now: now)
        let retrying = AuditDeliveryPresentation.summary(status(failures: 3), now: now)
        let healthy = AuditDeliveryPresentation.summary(status(), now: now)

        #expect(paused.canResume)
        #expect(!retrying.canResume)
        #expect(!healthy.canResume)
        #expect(Set([paused.rows[0].value, retrying.rows[0].value, healthy.rows[0].value]).count == 3)
    }

    @Test func zeroCountsAndAnEmptyBacklogAddNoRows() {
        let quiet = AuditDeliveryPresentation.summary(status(), now: now)
        let busy = AuditDeliveryPresentation.summary(status(
            failures: 2,
            rejected: 1,
            failure: AuditDeliveryFailureV5Ffi(kind: .receiverRetryable, httpStatus: 503, atMs: ms(now) - 60_000),
            backlog: AuditDeliveryBacklogV5Ffi(
                undeliveredBytes: 4_096, undeliveredSegments: 2, gaps: 1,
                oldestUndeliveredAtMs: ms(now) - 3_600_000, observedAtMs: ms(now)
            )
        ), now: now)

        #expect(busy.rows.count > quiet.rows.count)
        #expect(Set(busy.rows.map(\.title)).isSuperset(of: quiet.rows.map(\.title)))
        #expect(busy.rows.count - quiet.rows.count == 6)
    }

    @Test func aReceiverAnswerAddsItsHTTPStatusToTheFailure() {
        let answered = AuditDeliveryFailureV5Ffi(kind: .receiverBlocked, httpStatus: 403, atMs: 0)
        let silent = AuditDeliveryFailureV5Ffi(kind: .receiverBlocked, httpStatus: nil, atMs: 0)

        #expect(AuditDeliveryPresentation.failureText(answered).contains("403"))
        #expect(AuditDeliveryPresentation.failureText(answered).hasPrefix(AuditDeliveryPresentation.failureText(silent)))
    }

    @Test func everyFailureKindHasItsOwnText() {
        let kinds: [AuditDeliveryFailureKindV5Ffi] = [
            .stateOverLimit, .tooManyOpenFiles, .localIo, .localBlocked,
            .receiverBlocked, .receiverRejected, .receiverRetryable, .noResponse, .internal,
        ]
        let texts = kinds.map { AuditDeliveryPresentation.failureText(.init(kind: $0, httpStatus: nil, atMs: 0)) }
        #expect(Set(texts).count == kinds.count)
    }

    // MARK: - Delivery status model

    @Test func theModelShowsOnlyTheActiveProfilesRow() async {
        let source = AuditDeliverySourceStub(activeAccountRef: active)
        source.statuses = [status(account: other, paused: true), status(account: active.uppercased())]
        let model = AuditDeliveryStatusModel()

        await model.reload(using: source)
        #expect(model.status?.accountRef.lowercased() == active)
        #expect(model.status?.paused == false)

        source.statuses = [status(account: other)]
        await model.reload(using: source)
        #expect(model.hasLoaded)
        #expect(model.status == nil)
    }

    @Test func aStatusReadForAPreviousProfileIsIgnored() async {
        let source = AuditDeliverySourceStub(activeAccountRef: active)
        source.statuses = [status(account: active)]
        source.onRead = { source.activeAccountRef = self.other }
        let model = AuditDeliveryStatusModel()

        await model.reload(using: source)

        #expect(!model.hasLoaded)
        #expect(model.status == nil)
    }

    @Test func resumeRunsTheDeliveryPassThenRereads() async {
        let source = AuditDeliverySourceStub(activeAccountRef: active)
        source.statuses = [status(account: active, paused: true)]
        source.onResume = { source.statuses = [self.status(account: self.active)] }
        let model = AuditDeliveryStatusModel()
        await model.reload(using: source)

        await model.resume(using: source)

        #expect(source.resumeCount == 1)
        #expect(model.status?.paused == false)
        #expect(!model.isResuming)
        #expect(source.presentedToasts.isEmpty)
    }

    @Test func aFailedResumeTellsTheUserAndStillRereads() async {
        let source = AuditDeliverySourceStub(activeAccountRef: active)
        source.statuses = [status(account: active, paused: true)]
        source.resumeError = MarmotKitError.Runtime(details: "receiver unreachable")
        let model = AuditDeliveryStatusModel()

        await model.resume(using: source)

        #expect(source.presentedToasts.count == 1)
        #expect(model.status?.paused == true)
    }

    // MARK: - Retention

    @Test func retentionChoicesKeepAStoredValueAndStayInMDKsRange() {
        #expect(AuditLogRetentionPresentation.options(including: 30) == AuditLogRetentionPresentation.standardDays)
        let custom = AuditLogRetentionPresentation.options(including: 10)
        #expect(custom.contains(10))
        #expect(custom == custom.sorted())
        for out in [UInt32(0), 99] {
            #expect(AuditLogRetentionPresentation.options(including: out)
                .allSatisfy(AuditLogRetentionPresentation.dayRange.contains))
        }
    }

    @Test func aLongerPeriodSavesAtOnceAndKeepsTheSizeBudget() async {
        let source = AuditLogRetentionSourceStub(stored: AuditLogRetentionFfi(maxAgeDays: 7, maxBytesPerAccount: 64 << 20))
        let model = AuditLogRetentionModel()
        await model.load(using: source)

        await model.choose(days: 30, using: source)

        #expect(model.pendingShorterDays == nil)
        #expect(source.saved == [AuditLogRetentionFfi(maxAgeDays: 30, maxBytesPerAccount: 64 << 20)])
        #expect(model.retention?.maxAgeDays == 30)
    }

    @Test func aShorterPeriodWaitsForConfirmation() async {
        let source = AuditLogRetentionSourceStub(stored: AuditLogRetentionFfi(maxAgeDays: 30, maxBytesPerAccount: 256 << 20))
        let model = AuditLogRetentionModel()
        await model.load(using: source)

        await model.choose(days: 7, using: source)
        #expect(model.pendingShorterDays == 7)
        #expect(source.saved.isEmpty)

        // The alert's dismissal clears the pending value before its button's task runs.
        model.pendingShorterDays = nil
        await model.confirmShorter(days: 7, using: source)

        #expect(source.saved == [AuditLogRetentionFfi(maxAgeDays: 7, maxBytesPerAccount: 256 << 20)])
        #expect(model.retention?.maxAgeDays == 7)
    }

    @Test func aFailedSaveKeepsTheStoredPeriodAndTellsTheUser() async {
        let source = AuditLogRetentionSourceStub(stored: AuditLogRetentionFfi(maxAgeDays: 7, maxBytesPerAccount: 64 << 20))
        source.saveError = MarmotKitError.Io(details: "disk full")
        let model = AuditLogRetentionModel()
        await model.load(using: source)

        await model.choose(days: 14, using: source)

        #expect(model.retention?.maxAgeDays == 7)
        #expect(source.presentedToasts.count == 1)
        #expect(!model.isSaving)
    }

    // MARK: - Fixtures

    private func ms(_ date: Date) -> UInt64 { UInt64(date.timeIntervalSince1970 * 1_000) }

    private func status(
        account: String? = nil,
        configured: Bool = true,
        paused: Bool = false,
        failures: UInt64 = 0,
        rejected: UInt64 = 0,
        failure: AuditDeliveryFailureV5Ffi? = nil,
        backlog: AuditDeliveryBacklogV5Ffi? = nil
    ) -> AuditDeliveryStatusV5Ffi {
        AuditDeliveryStatusV5Ffi(
            accountRef: account ?? active,
            destinationConfigured: configured,
            lastSuccessAtMs: ms(now) - 120_000,
            lastFailure: failure,
            consecutiveFailures: failures,
            rejectedBatches: rejected,
            paused: paused,
            backlog: backlog
        )
    }
}

@MainActor
private final class AuditDeliverySourceStub: AuditDeliveryDataSource {
    var activeAccountRef: String?
    var statuses: [AuditDeliveryStatusV5Ffi] = []
    var resumeError: (any Error)?
    var onRead: (() -> Void)?
    var onResume: (() -> Void)?
    private(set) var resumeCount = 0
    private(set) var presentedToasts: [Toast] = []

    init(activeAccountRef: String?) {
        self.activeAccountRef = activeAccountRef
    }

    func auditDeliveryStatus() async throws -> [AuditDeliveryStatusV5Ffi] {
        onRead?()
        return statuses
    }

    func resumeAuditDelivery() async throws {
        resumeCount += 1
        if let resumeError { throw resumeError }
        onResume?()
    }

    func present(_ toast: Toast) {
        presentedToasts.append(toast)
    }
}

@MainActor
private final class AuditLogRetentionSourceStub: AuditLogRetentionDataSource {
    var stored: AuditLogRetentionFfi
    var saveError: (any Error)?
    private(set) var saved: [AuditLogRetentionFfi] = []
    private(set) var presentedToasts: [Toast] = []

    init(stored: AuditLogRetentionFfi) {
        self.stored = stored
    }

    func auditLogRetention() async throws -> AuditLogRetentionFfi { stored }

    func setAuditLogRetention(_ retention: AuditLogRetentionFfi) async throws -> AuditLogRetentionFfi {
        if let saveError { throw saveError }
        saved.append(retention)
        stored = retention
        return retention
    }

    func present(_ toast: Toast) {
        presentedToasts.append(toast)
    }
}
