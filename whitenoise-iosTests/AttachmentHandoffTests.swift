import Foundation
import MarmotKit
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

    private func waitForReleases(_ releaser: FakeReleaser, count: Int) async -> [String] {
        for _ in 0..<200 {
            let leases = await releaser.leases
            if leases.count >= count { return leases }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await releaser.leases
    }

    // MARK: Release

    @Test func releaseRetriesOnlyIoUntilItSucceeds() async {
        let releaser = FakeReleaser([MarmotKitError.Io(details: "busy"), MarmotKitError.Io(details: "busy"), nil])
        var sleeps: [Duration] = []
        let outcome = await AttachmentHandoffRelease.run(lease: lease, using: releaser) { sleeps.append($0) }
        #expect(outcome == .released)
        #expect(await releaser.leases == [lease, lease, lease])
        #expect(sleeps == [AttachmentHandoffRelease.retryDelay(afterAttempt: 1),
                           AttachmentHandoffRelease.retryDelay(afterAttempt: 2)])
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
        let failures = Array(repeating: MarmotKitError.Io(details: "busy") as Error?, count: 10)
        let releaser = FakeReleaser(failures)
        var sleeps = 0
        let outcome = await AttachmentHandoffRelease.run(lease: lease, using: releaser) { _ in sleeps += 1 }
        #expect(outcome == .abandoned)
        #expect(await releaser.leases.count == AttachmentHandoffRelease.maxAttempts)
        #expect(sleeps == AttachmentHandoffRelease.maxAttempts - 1)
    }

    @Test func retryDelayGrowsAndStaysBounded() {
        let delays = (1...8).map(AttachmentHandoffRelease.retryDelay(afterAttempt:))
        #expect(delays.first == .milliseconds(250))
        #expect(zip(delays, delays.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(delays.last == .seconds(4))
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

    // MARK: Opening

    @Test func heldAttachmentOpensWithoutAcquiring() async throws {
        var opens = 0
        var acquires = 0
        let opened = try await AttachmentHandoffOpening.open(
            handoff: { opens += 1; return "lease" },
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
                                                        acquire: {})
        }
        #expect(opens == 2)
    }

    @Test func failedAcquisitionDoesNotOpenAgain() async {
        var opens = 0
        await #expect(throws: AttachmentReadError.self) {
            _ = try await AttachmentHandoffOpening.open(handoff: { () -> String? in opens += 1; return nil },
                                                        acquire: { throw AttachmentReadError.unavailable })
        }
        #expect(opens == 1)
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
        for _ in 0..<200 where !control.isCancelled() { try await Task.sleep(for: .milliseconds(5)) }
        #expect(control.isCancelled())
        gate.continuation.finish()
        #expect(try await caller.value == "lease")
    }
}
