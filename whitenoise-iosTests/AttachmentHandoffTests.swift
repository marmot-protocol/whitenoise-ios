import Foundation
import MarmotKit
import Synchronization
import Testing
@testable import whitenoise_ios

@MainActor
struct AttachmentHandoffTests {
    private actor FakeReleaser: AttachmentHandoffReleasing {
        private var script: [Error?]
        private(set) var leases: [String] = []

        init(_ script: [Error?] = []) { self.script = script }

        func releaseAttachmentHandoff(lease: String) async throws {
            leases.append(lease)
            if !script.isEmpty, let error = script.removeFirst() { throw error }
        }
    }

    private let lease = String(repeating: "a", count: 32)

    /// Callers assert on the returned leases, so a timeout still fails the test.
    private func waitForReleases(_ releaser: FakeReleaser, count: Int) async -> [String] {
        try? await eventually { await releaser.leases.count >= count }
        return await releaser.leases
    }

    // MARK: Release

    @Test func releaseRetriesIoAndClosedRuntimesUntilItSucceeds() async {
        let releaser = FakeReleaser([MarmotKitError.Io(details: "busy"),
                                     MarmotKitError.StorageClosed(details: "suspended"), nil])
        var sleeps: [Duration] = []
        let outcome = await AttachmentHandoffRelease.run(lease: lease, using: releaser) { sleeps.append($0) }
        #expect(outcome == .released)
        #expect(await releaser.leases == [lease, lease, lease])
        #expect(sleeps == [AttachmentHandoffRelease.retryDelay(afterAttempt: 1),
                           AttachmentHandoffRelease.retryDelay(afterAttempt: 2)])
    }

    @Test func releaseWaitsForAnOpenRuntimeAndUsesTheOneOpenThen() async {
        let resumed = FakeReleaser()
        let runtimes = Mutex<[FakeReleaser?]>([nil, nil, resumed])
        let releaser = LiveRuntimeHandoffReleaser {
            runtimes.withLock { $0.isEmpty ? resumed : $0.removeFirst() }
        }
        var sleeps = 0
        let outcome = await AttachmentHandoffRelease.run(lease: lease, using: releaser) { _ in sleeps += 1 }
        #expect(outcome == .released)
        #expect(sleeps == 2)
        #expect(await resumed.leases == [lease])
    }

    @Test func malformedLeaseIsNeverRetried() async {
        let releaser = FakeReleaser([MarmotKitError.InvalidMediaReference(details: "invalid lease")])
        var sleeps = 0
        let outcome = await AttachmentHandoffRelease.run(lease: "bad", using: releaser) { _ in sleeps += 1 }
        #expect(outcome == .rejected)
        #expect(await releaser.leases.count == 1)
        #expect(sleeps == 0)
    }

    @Test func persistentIoFailureStopsAfterTheAttemptBudget() async {
        let failures = Array(repeating: MarmotKitError.Io(details: "busy") as Error?,
                             count: AttachmentHandoffRelease.maxAttempts + 2)
        let releaser = FakeReleaser(failures)
        var sleeps = 0
        let outcome = await AttachmentHandoffRelease.run(lease: lease, using: releaser) { _ in sleeps += 1 }
        #expect(outcome == .abandoned)
        #expect(await releaser.leases.count == AttachmentHandoffRelease.maxAttempts)
        #expect(sleeps == AttachmentHandoffRelease.maxAttempts - 1)
    }

    @Test func retryDelayGrowsAndStaysBounded() {
        let delays = (1...12).map(AttachmentHandoffRelease.retryDelay(afterAttempt:))
        #expect(delays.first == .milliseconds(250))
        #expect(zip(delays, delays.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(delays.last == .seconds(30))
    }

    @Test func completionAndDismissalReleaseTheLeaseOnce() async {
        let releaser = FakeReleaser()
        let handoff = AttachmentHandoffFfi(lease: lease, path: "/tmp/handoff/\(lease)/Report.pdf",
                                           byteCount: 3, mediaType: "application/pdf", fileName: "Report.pdf")
        let leased = AttachmentHandoffLease(handoff, releaser: releaser)
        let file = AttachmentShareFile(lease: leased)
        #expect(file.url.lastPathComponent == "Report.pdf")
        #expect(file.url.isFileURL)

        let first = leased.release()
        file.finish()
        file.finish()
        #expect(first != nil)
        #expect(leased.release() == nil)
        #expect(await first?.value == .released)
        #expect(await releaser.leases == [lease])
    }

    @Test func droppingAnUnreleasedLeaseReleasesIt() async {
        let releaser = FakeReleaser()
        do {
            _ = AttachmentHandoffLease(lease: lease, path: "/tmp/handoff/copy.pdf", releaser: releaser)
        }
        #expect(await waitForReleases(releaser, count: 1) == [lease])
    }

    @Test func hostExportHasNothingToRelease() {
        let file = AttachmentShareFile(hostURL: URL(fileURLWithPath: "/tmp/draft.pdf"))
        #expect(file.lease == nil)
        file.finish()
    }

    // MARK: Protection

    @Test func leasedCopyIsRaisedToCompleteProtection() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("handoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Report.pdf")
        try Data("%PDF-1.7".utf8).write(to: url, options: .noFileProtection)
        let releaser = FakeReleaser()
        let leased = AttachmentHandoffLease(lease: lease, path: url.path, releaser: releaser)

        try leased.protect()

        if AttachmentHandoffLease.dataProtectionEnforced {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect(attributes[.protectionKey] as? FileProtectionType == .complete)
        }
        #expect(try Data(contentsOf: url) == Data("%PDF-1.7".utf8))
        #expect(await releaser.leases.isEmpty)
        leased.release()
    }

    @Test func onlyCompleteProtectionIsShared() {
        #expect(AttachmentHandoffLease.isComplete(.complete, enforced: true))
        #expect(!AttachmentHandoffLease.isComplete(nil, enforced: true))
        #expect(!AttachmentHandoffLease.isComplete(.completeUntilFirstUserAuthentication, enforced: true))
        #expect(!AttachmentHandoffLease.isComplete(.completeUnlessOpen, enforced: true))
        #expect(!AttachmentHandoffLease.isComplete(FileProtectionType.none, enforced: true))
        #expect(AttachmentHandoffLease.isComplete(nil, enforced: false))
        #expect(!AttachmentHandoffLease.isComplete(.completeUntilFirstUserAuthentication, enforced: false))
    }

    @Test func copyThatCannotBeProtectedIsReleasedInsteadOfShared() async {
        let releaser = FakeReleaser()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("handoff-\(UUID().uuidString)/Report.pdf").path
        let leased = AttachmentHandoffLease(lease: lease, path: missing, releaser: releaser)

        #expect(throws: AttachmentHandoffFailure.unprotected) { try leased.protect() }
        #expect(await waitForReleases(releaser, count: 1) == [lease])
        #expect(leased.release() == nil)
    }

    // MARK: Opening

    @Test func heldAttachmentOpensWithoutAcquiring() async throws {
        var opens = 0
        var acquires = 0
        let opened = try await AttachmentHandoffOpening.open(
            handoff: { opens += 1; return "lease" },
            hostHasBytes: false,
            acquire: { acquires += 1 }
        )
        #expect(opened == "lease")
        #expect(opens == 1)
        #expect(acquires == 0)
    }

    @Test func missAcquiresThenOpensOnce() async throws {
        var results: [String?] = [nil, "lease"]
        var acquires = 0
        let opened = try await AttachmentHandoffOpening.open(
            handoff: { results.removeFirst() },
            hostHasBytes: false,
            acquire: { acquires += 1 }
        )
        #expect(opened == "lease")
        #expect(acquires == 1)
        #expect(results.isEmpty)
    }

    @Test func stillMissingAfterAcquisitionIsNotHeldLocally() async {
        var opens = 0
        await #expect(throws: AttachmentHandoffFailure.notHeldLocally) {
            _ = try await AttachmentHandoffOpening.open(handoff: { () -> String? in opens += 1; return nil },
                                                        hostHasBytes: false, acquire: {})
        }
        #expect(opens == 2)
    }

    @Test func failedAcquisitionDoesNotOpenAgain() async {
        var opens = 0
        await #expect(throws: AttachmentReadError.self) {
            _ = try await AttachmentHandoffOpening.open(handoff: { () -> String? in opens += 1; return nil },
                                                        hostHasBytes: false,
                                                        acquire: { throw AttachmentReadError.unavailable })
        }
        #expect(opens == 1)
    }

    @Test func ownSendMDKDoesNotHoldFallsBackToTheHostBytes() async throws {
        var opens = 0
        var acquires = 0
        let opened = try await AttachmentHandoffOpening.open(
            handoff: { () -> String? in opens += 1; return nil },
            hostHasBytes: true,
            acquire: { acquires += 1 }
        )
        #expect(opened == nil)
        #expect(opens == 1)
        #expect(acquires == 0)
    }

    @Test func ownSendMDKHoldsStillOpensTheHandoff() async throws {
        let opened = try await AttachmentHandoffOpening.open(handoff: { "lease" }, hostHasBytes: true, acquire: {})
        #expect(opened == "lease")
    }

    // MARK: Routing

    private static let target = AttachmentLocalTargetFfi(messageIdHex: String(repeating: "1", count: 64),
        sourceMessageIdHex: String(repeating: "2", count: 64), attachmentIndex: 0)

    private func document(localData: Data? = nil, localTarget: AttachmentLocalTargetFfi? = nil,
                          sourceHint: AttachmentSourceHint? = nil) -> MessageMediaAttachment {
        var item = MessageMediaAttachment(id: "row:0", reference: nil, fileName: "Report.pdf",
            mediaType: "application/pdf", dim: nil, localData: localData, localTarget: localTarget)
        item.sourceHint = sourceHint
        return item
    }

    @Test func confirmedOwnSendWithHostBytesStillUsesItsSlot() {
        let item = document(localData: Data("%PDF".utf8), localTarget: Self.target)
        #expect(AttachmentHandoffSource(item) == .target(Self.target))
    }

    @Test func slotlessDraftKeepsTheHostExport() {
        #expect(AttachmentHandoffSource(document(localData: Data("%PDF".utf8))) == .none)
    }

    @Test func hintIsResolvedWhenTheRowHasNoTarget() {
        let hint = AttachmentSourceHint(messageID: String(repeating: "1", count: 64), slot: 2)
        #expect(AttachmentHandoffSource(document(sourceHint: hint)) == .hint(hint))
        #expect(AttachmentHandoffSource(document(localTarget: Self.target, sourceHint: hint)) == .target(Self.target))
    }

    @Test func reportedMessageMediaKeepsItsOriginalSlot() {
        let messageID = String(repeating: "3", count: 64)
        let sourceID = String(repeating: "4", count: 64)
        let reference = MediaAttachmentReferenceFfi(
            locators: [MediaLocatorFfi(kind: "blossom-v1", value: "https://example.com/report.pdf")],
            ciphertextSha256: String(repeating: "a", count: 64), plaintextSha256: String(repeating: "b", count: 64),
            nonceHex: String(repeating: "2", count: 24), fileName: "Report.pdf", mediaType: "application/pdf",
            version: .v1, sourceEpoch: 1, dim: nil, thumbhash: nil)
        let message = TimelineMessageRecordFfi(
            messageIdHex: messageID, sourceMessageIdHex: sourceID, direction: "received",
            groupIdHex: String(repeating: "5", count: 64), sender: String(repeating: "6", count: 64),
            plaintext: "", contentTokens: .emptyDocument, kind: 9, tags: [],
            timelineAt: 1, receivedAt: 1, replyToMessageIdHex: nil, replyPreview: nil,
            mediaJson: nil, media: [reference], agentTextStreamJson: nil,
            groupSystem: nil, poll: nil, reactions: TimelineReactionSummaryFfi(byEmoji: [], userReactions: []),
            edit: nil, deleted: false, deletedByMessageIdHex: nil, invalidationStatus: nil)
        let items = GroupModerationModel.mediaItems(for: message, reportIdHex: "r1")
        #expect(items.count == 1)
        let slot = AttachmentLocalTargetFfi(messageIdHex: messageID, sourceMessageIdHex: sourceID,
                                            attachmentIndex: 0)
        #expect(items.first?.localTarget == slot)
        #expect(items.first.map(AttachmentHandoffSource.init) == .target(slot))
    }

    @Test func storageFullAndControlCancellationMapToUserStates() {
        let full = AttachmentHandoffOpening.failure(for: MarmotKitError.StorageFull(details: "reserve"),
                                                    controlCancelled: false)
        #expect(full as? AttachmentHandoffFailure == .storageFull)

        // MDK reports a copy cancelled through its control as invalid media.
        let cancelled = AttachmentHandoffOpening.failure(
            for: MarmotKitError.InvalidMediaReference(details: "media transfer cancelled"), controlCancelled: true)
        #expect(cancelled is CancellationError)

        let other = AttachmentHandoffOpening.failure(for: AttachmentReadError.stale, controlCancelled: false)
        #expect(other as? AttachmentReadError == .stale)
    }

    @Test func cancellingTheCallerCancelsThroughTheControlAndKeepsTheResult() async throws {
        let control = MediaFileTransferControlFfi()
        let gate = AsyncStream<Void>.makeStream()
        let caller = Task {
            try await AttachmentHandoffOpening.shielded(cancel: { control.cancel() }) {
                for await _ in gate.stream {}
                return "lease"
            }
        }
        caller.cancel()
        // The shielded call is still running: only the control saw the cancellation.
        try await eventually { control.isCancelled() }
        #expect(control.isCancelled())
        gate.continuation.finish()
        #expect(try await caller.value == "lease")
    }
}
