import Foundation
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

struct MediaFileUploadTests {
    private static func attachment(
        _ fileName: String = "clip.mov",
        mediaType: String = "video/quicktime",
        bytes: Int = 1_024
    ) -> MediaDraftAttachment {
        MediaDraftAttachment(fileName: fileName, mediaType: mediaType, data: Data(repeating: 7, count: bytes), dim: "640x480")
    }

    private static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaFileUploadTests-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: Route

    @Test func smallPhotosAndVoiceNotesStayOnTheByteArrayPath() {
        #expect(MediaUploadRoute.route(kinds: [.image, .image], byteCounts: [900_000, 1_200_000]) == .bytes)
        #expect(MediaUploadRoute.route(kinds: [.audio], byteCounts: [300_000]) == .bytes)
    }

    @Test func videosAndDocumentsAlwaysUseFiles() {
        #expect(MediaUploadRoute.route(kinds: [.video], byteCounts: [10]) == .files)
        #expect(MediaUploadRoute.route(kinds: [.document], byteCounts: [10]) == .files)
        #expect(MediaUploadRoute.route(kinds: [.image, .video], byteCounts: [10, 10]) == .files)
    }

    @Test func aLargeBatchUsesFilesFromTheThreshold() {
        let threshold = MediaUploadRoute.fileBackedThresholdBytes
        #expect(MediaUploadRoute.route(kinds: [.image], byteCounts: [threshold - 1]) == .bytes)
        #expect(MediaUploadRoute.route(kinds: [.image], byteCounts: [threshold]) == .files)
        #expect(MediaUploadRoute.route(kinds: [.image, .audio], byteCounts: [threshold / 2, threshold / 2]) == .files)
    }

    @Test func overflowingTotalsUseFiles() {
        #expect(MediaUploadRoute.route(kinds: [.image, .image], byteCounts: [Int.max, 1]) == .files)
    }

    @Test func routeReadsDraftKindAndSize() {
        #expect(MediaUploadRoute.route(for: [Self.attachment("photo.jpg", mediaType: "image/jpeg")]) == .bytes)
        #expect(MediaUploadRoute.route(for: [Self.attachment()]) == .files)
    }

    // MARK: Limit

    @Test func ciphertextCountsOneTagPerAttachment() {
        #expect(MediaFileUploadLimit.ciphertextBytes(plaintextByteCounts: [100, 200]) == 332)
        #expect(MediaFileUploadLimit.ciphertextBytes(plaintextByteCounts: []) == 0)
    }

    @Test func batchAtTheLimitIsAccepted() throws {
        try MediaFileUploadLimit.validate(plaintextByteCounts: [984], limit: 1_000)
    }

    @Test func batchOverTheLimitIsRejectedAsASizeRejection() {
        #expect(throws: MediaFileUploadFailure.exceedsTransferLimit(attachmentCount: 2)) {
            try MediaFileUploadLimit.validate(plaintextByteCounts: [500, 485], limit: 1_000)
        }
        #expect(OutgoingSendSizePolicy.isSizeRejection(MediaFileUploadFailure.exceedsTransferLimit(attachmentCount: 1)))
        #expect(!OutgoingSendSizePolicy.isSizeRejection(MediaFileUploadFailure.cancelled))
    }

    @Test func limitMessageNamesOneOrSeveralAttachments() {
        #expect(MediaFileUploadFailure.exceedsTransferLimit(attachmentCount: 1).errorDescription
            == L10n.string("That attachment is too large to send."))
        #expect(MediaFileUploadFailure.exceedsTransferLimit(attachmentCount: 3).errorDescription
            == L10n.string("These attachments are too large to send together."))
    }

    @Test func mdkTransferBoundErrorIsASizeRejection() {
        let error = MarmotKitError.InvalidMediaReference(details: "file attachments exceed transfer bound")
        let only = Self.attachment()
        #expect(OutgoingSendSizePolicy.rejection(for: error, phase: .upload(candidates: [only])) == .attachments([only.id]))
    }

    @Test func overflowingBatchIsRejected() {
        #expect(MediaFileUploadLimit.ciphertextBytes(plaintextByteCounts: [Int.max, Int.max, Int.max]) == nil)
        #expect(throws: MediaFileUploadFailure.self) {
            try MediaFileUploadLimit.validate(plaintextByteCounts: [Int.max, Int.max, Int.max], limit: .max)
        }
    }

    @Test func mdkPublishesItsTransferBound() {
        #expect(maxFileMediaCiphertextBytes() > UInt64(MediaDraftProcessor.maxAttachmentBytes))
    }

    // MARK: Cancellation vs failure

    @Test func requestedCancellationMapsToCancelled() {
        let error = MarmotKitError.InvalidMediaReference(details: "media transfer cancelled")
        let mapped = MediaFileUploadErrorMapping.mapped(error, cancellationRequested: true)
        #expect(MediaFileUploadErrorMapping.isCancellation(mapped))
    }

    @Test func failureWithoutCancellationKeepsTheOriginalError() {
        let error = MarmotKitError.InvalidMediaReference(details: "media transfer cancelled")
        let mapped = MediaFileUploadErrorMapping.mapped(error, cancellationRequested: false)
        #expect(!MediaFileUploadErrorMapping.isCancellation(mapped))
        #expect((mapped as? MarmotKitError) == error)
    }

    @MainActor
    @Test func missingStatusIsDefinitiveForFileUploadErrors() {
        #expect(!MediaSubmissionRecovery.isAmbiguousWithoutStatus(MediaFileUploadFailure.cancelled))
        #expect(!MediaSubmissionRecovery.isAmbiguousWithoutStatus(MediaFileUploadFailure.sourceUnavailable))
        #expect(MediaSubmissionRecovery.isAmbiguousWithoutStatus(CancellationError()))
        #expect(MediaSubmissionRecovery.isAmbiguousWithoutStatus(MarmotKitError.AccountWorkerResponseTimedOut))
        #expect(!MediaSubmissionRecovery.isAmbiguousWithoutStatus(MarmotKitError.Runtime(details: "relay disconnected")))
    }

    // MARK: Progress

    @Test func singleAttachmentProgressCoversSnapshotEncryptionAndTransfer() {
        let total = UInt64(3 * (1_000 + 16))
        #expect(MediaFileUploadProgress.fraction(processedBytes: 0, plaintextByteCounts: [1_000]) == 0)
        #expect(MediaFileUploadProgress.fraction(processedBytes: total / 2, plaintextByteCounts: [1_000]) == 0.5)
        #expect(MediaFileUploadProgress.fraction(processedBytes: total, plaintextByteCounts: [1_000]) == 1)
        #expect(MediaFileUploadProgress.fraction(processedBytes: total * 2, plaintextByteCounts: [1_000]) == 1)
    }

    @Test func batchesAndEmptyFilesStayIndeterminate() {
        #expect(MediaFileUploadProgress.fraction(processedBytes: 10, plaintextByteCounts: [1_000, 2_000]) == nil)
        #expect(MediaFileUploadProgress.fraction(processedBytes: 10, plaintextByteCounts: []) == nil)
        #expect(MediaFileUploadProgress.fraction(processedBytes: 10, plaintextByteCounts: [0]) == nil)
    }

    // MARK: Source files

    @Test func stagedSourcesAreRegularFilesWithTheDraftBytes() throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let draft = Self.attachment(bytes: 4_096)

        let sources = try MediaUploadSourceFiles.stageSynchronously([draft], in: directory, now: Date())

        let request = try #require(sources.requests.first)
        #expect(request.expectedSize == 4_096)
        #expect(request.fileName == "clip.mov")
        #expect(request.mediaType == "video/quicktime")
        #expect(request.dim == "640x480")
        #expect(MediaUploadSourceFiles.isRegularFile(at: URL(fileURLWithPath: request.sourcePath)))
        #expect(try Data(contentsOf: URL(fileURLWithPath: request.sourcePath)) == draft.data)
        MediaUploadSourceFiles.remove(sources.urls)
        #expect(!FileManager.default.fileExists(atPath: request.sourcePath))
    }

    @Test func symlinksAreNotRegularFiles() throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("target")
        try Data([1]).write(to: target)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(MediaUploadSourceFiles.isRegularFile(at: target))
        #expect(!MediaUploadSourceFiles.isRegularFile(at: link))
        #expect(!MediaUploadSourceFiles.isRegularFile(at: directory))
    }

    @Test func staleLeftoversAreSweptAndRecentFilesKept() throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        let stale = directory.appendingPathComponent("stale")
        let recent = directory.appendingPathComponent("recent")
        try Data([1]).write(to: stale)
        try Data([1]).write(to: recent)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-MediaUploadSourceFiles.staleAge - 60)],
            ofItemAtPath: stale.path
        )

        MediaUploadSourceFiles.removeStale(in: directory, olderThan: MediaUploadSourceFiles.staleAge, now: now)

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: recent.path))
    }

    // MARK: Runner

    @Test func runnerKeepsSourcesUntilTheUploadReturnsThenRemovesThem() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let draft = Self.attachment(bytes: 2_048)
        let seen = PathsSeen()

        let value = try await MediaFileUploadRunner.run(
            [draft], control: MediaFileTransferControlFfi(), limit: .max, directory: directory
        ) { requests in
            let paths = requests.map(\.sourcePath)
            await seen.record(paths, existing: paths.allSatisfy { FileManager.default.fileExists(atPath: $0) })
            return 42
        }

        #expect(value == 42)
        let recorded = await seen.paths
        #expect(recorded.count == 1)
        #expect(await seen.allExisted)
        #expect(recorded.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
    }

    @Test func runnerRejectsAnOversizedBatchBeforeWritingAnything() async {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let seen = PathsSeen()

        await #expect(throws: MediaFileUploadFailure.exceedsTransferLimit(attachmentCount: 1)) {
            try await MediaFileUploadRunner.run(
                [Self.attachment(bytes: 100)], control: MediaFileTransferControlFfi(), limit: 50, directory: directory
            ) { requests in
                await seen.record(requests.map(\.sourcePath), existing: true)
            }
        }
        #expect(await seen.paths.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func runnerReportsAnErrorAfterCancelAsCancelledAndCleansUp() async {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let control = MediaFileTransferControlFfi()
        let seen = PathsSeen()

        await #expect(throws: MediaFileUploadFailure.cancelled) {
            try await MediaFileUploadRunner.run(
                [Self.attachment()], control: control, limit: .max, directory: directory
            ) { requests in
                await seen.record(requests.map(\.sourcePath), existing: true)
                control.cancel()
                throw MarmotKitError.InvalidMediaReference(details: "media transfer cancelled")
            }
        }
        #expect(await seen.paths.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
    }

    @Test func runnerPassesFailuresThroughWhenNothingWasCancelled() async {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let failure = MarmotKitError.Runtime(details: "relay disconnected")

        await #expect(throws: failure) {
            try await MediaFileUploadRunner.run(
                [Self.attachment()], control: MediaFileTransferControlFfi(), limit: .max, directory: directory
            ) { _ in
                throw failure
            }
        }
    }

    @Test func cancellingTheTaskCancelsTheTransferControl() async {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let control = MediaFileTransferControlFfi()
        let started = AsyncFlag()

        let task = Task {
            try await MediaFileUploadRunner.run(
                [Self.attachment()], control: control, limit: .max, directory: directory
            ) { _ in
                await started.set()
                // Stands in for MDK: it returns only once its control is cancelled.
                while !control.isCancelled() {
                    try? await Task.sleep(for: .milliseconds(5))
                }
                throw MarmotKitError.InvalidMediaReference(details: "media transfer cancelled")
            }
        }
        await started.wait()
        task.cancel()

        let result = await task.result
        #expect(control.isCancelled())
        #expect(throws: MediaFileUploadFailure.cancelled) { try result.get() }
    }

    // MARK: Progress store

    @MainActor
    @Test func progressStoreReportsOnlyItsSingleTrackedAttachment() async {
        let store = MediaUploadProgressStore()
        let draft = Self.attachment(bytes: 1_000)
        let control = MediaFileTransferControlFfi()

        let tracking = store.track([draft], control: control)
        for _ in 0..<100 where store.fraction(forItemIds: [draft.id.uuidString]) == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(store.fraction(forItemIds: [draft.id.uuidString]) == 0)
        #expect(store.fraction(forItemIds: [UUID().uuidString]) == nil)
        #expect(store.fraction(forItemIds: [draft.id.uuidString, UUID().uuidString]) == nil)

        tracking.cancel()
        await tracking.value
        #expect(store.fraction(forItemIds: [draft.id.uuidString]) == nil)
    }
}

private actor PathsSeen {
    private(set) var paths: [String] = []
    private(set) var allExisted = true

    func record(_ paths: [String], existing: Bool) {
        self.paths.append(contentsOf: paths)
        allExisted = allExisted && existing
    }
}

private actor AsyncFlag {
    private var isSet = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func set() {
        isSet = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func wait() async {
        guard !isSet else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
