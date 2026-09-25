import Foundation
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

@MainActor
struct DraftMediaPreuploadsTests {
    @Test func uploadsEachStagedAttachmentOnceAndHandsReferencesToSendInOrder() async {
        let probe = UploadProbe()
        let uploads = DraftMediaPreuploads(uploader: probe.uploader())
        let first = attachment("first.jpg")
        let second = attachment("second.jpg")

        uploads.reconcile([first, second], accountRef: "account")
        uploads.reconcile([first, second], accountRef: "account")
        let taken = uploads.take([second, first], accountRef: "account")

        var fileNames: [String?] = []
        for upload in taken {
            fileNames.append(await upload?.value?.fileName)
        }
        #expect(fileNames == ["second.jpg", "first.jpg"])
        #expect(probe.calls.count == 2)
    }

    @Test func removingAnAttachmentCancelsItsUpload() async {
        let probe = UploadProbe()
        let uploads = DraftMediaPreuploads(uploader: probe.uploader())
        let removed = attachment("removed.jpg")

        uploads.reconcile([removed], accountRef: "account")
        uploads.reconcile([], accountRef: "account")
        await probe.waitForCalls(1)

        #expect(probe.calls == [UploadCall(accountRef: "account", fileName: "removed.jpg", cancelled: true)])
        #expect(uploads.take([removed], accountRef: "account").allSatisfy { $0 == nil })
    }

    @Test func takenUploadSurvivesClearingTheComposer() async {
        let probe = UploadProbe()
        let uploads = DraftMediaPreuploads(uploader: probe.uploader())
        let sent = attachment("sent.jpg")

        uploads.reconcile([sent], accountRef: "account")
        let taken = uploads.take([sent], accountRef: "account")
        uploads.reconcile([], accountRef: "account")
        uploads.cancelAll()

        #expect(await taken.first??.value?.fileName == "sent.jpg")
    }

    @Test func switchingAccountsRestartsTheUploadUnderTheNewAccount() async {
        let probe = UploadProbe()
        let uploads = DraftMediaPreuploads(uploader: probe.uploader())
        let photo = attachment("photo.jpg")

        uploads.reconcile([photo], accountRef: "one")
        uploads.reconcile([photo], accountRef: "two")
        await probe.waitForCalls(2)

        #expect(Set(probe.calls) == [
            UploadCall(accountRef: "one", fileName: "photo.jpg", cancelled: true),
            UploadCall(accountRef: "two", fileName: "photo.jpg", cancelled: false),
        ])
        #expect(await uploads.take([photo], accountRef: "two").first??.value?.fileName == "photo.jpg")
    }

    @Test func uploadStartedForAnotherAccountIsNeverReused() {
        let probe = UploadProbe()
        let uploads = DraftMediaPreuploads(uploader: probe.uploader())
        let photo = attachment("photo.jpg")

        uploads.reconcile([photo], accountRef: "one")

        #expect(uploads.take([photo], accountRef: "two").allSatisfy { $0 == nil })
    }

    @Test func signedOutComposerStartsNoUploads() async {
        let probe = UploadProbe()
        let uploads = DraftMediaPreuploads(uploader: probe.uploader())
        let photo = attachment("photo.jpg")

        uploads.reconcile([photo], accountRef: nil)

        #expect(uploads.take([photo], accountRef: "account").allSatisfy { $0 == nil })
        #expect(probe.calls.isEmpty)
    }

    @Test func failedUploadResolvesToNilSoSendUploadsAgain() async {
        let uploads = DraftMediaPreuploads { _, _ in throw MarmotKitError.Runtime(details: "blossom unreachable") }
        let photo = attachment("photo.jpg")

        uploads.reconcile([photo], accountRef: "account")
        let taken = uploads.take([photo], accountRef: "account")

        #expect(await taken.first??.value == nil)
    }

    @Test func uploadStateFollowsTheUploadOutcome() async {
        let succeeding = DraftMediaPreuploads(uploader: UploadProbe().uploader())
        let failing = DraftMediaPreuploads { _, _ in throw MarmotKitError.Runtime(details: "blossom unreachable") }
        let photo = attachment("photo.jpg")

        succeeding.reconcile([photo], accountRef: "account")
        failing.reconcile([photo], accountRef: "account")
        #expect(succeeding.states[photo.id] == .uploading)
        #expect(failing.states[photo.id] == .uploading)

        await settle { succeeding.states[photo.id] != .uploading && failing.states[photo.id] != .uploading }
        #expect(succeeding.states[photo.id] == .uploaded)
        #expect(failing.states[photo.id] == .failed)
    }

    @Test func removedOrSentAttachmentsLeaveNoUploadState() async {
        let uploads = DraftMediaPreuploads(uploader: UploadProbe().uploader())
        let removed = attachment("removed.jpg")
        let sent = attachment("sent.jpg")

        uploads.reconcile([removed, sent], accountRef: "account")
        uploads.reconcile([sent], accountRef: "account")
        let taken = uploads.take([sent], accountRef: "account")
        _ = await taken.first??.value

        #expect(uploads.states.isEmpty)
    }

    @Test(arguments: [
        (sourceEpoch: UInt64(4), currentEpoch: UInt64?(4), reusable: true),
        (sourceEpoch: UInt64(4), currentEpoch: UInt64?(nil), reusable: true),
        (sourceEpoch: UInt64(4), currentEpoch: UInt64?(5), reusable: false),
    ])
    func referenceIsReusableOnlyInItsOwnEpoch(sourceEpoch: UInt64, currentEpoch: UInt64?, reusable: Bool) {
        let resolved = DraftMediaPreuploadResolution.reusable(
            reference("photo.jpg", sourceEpoch: sourceEpoch),
            currentEpoch: currentEpoch
        )
        #expect((resolved != nil) == reusable)
    }

    @Test func missingReferenceIsNeverReusable() {
        #expect(DraftMediaPreuploadResolution.reusable(nil, currentEpoch: 1) == nil)
    }

    @Test func freshUploadsFillThePreparedGapsInAttachmentOrder() {
        let attachments = [attachment("a.jpg"), attachment("b.jpg"), attachment("c.jpg")]

        let resolved = DraftMediaPreuploadResolution.merged(
            attachments,
            prepared: [nil, reference("b.jpg"), nil],
            uploaded: [reference("a.jpg"), reference("c.jpg")]
        )

        #expect(resolved.references.map(\.fileName) == ["a.jpg", "b.jpg", "c.jpg"])
        #expect(resolved.attachments.map(\.id) == attachments.map(\.id))
    }

    @Test func unresolvedSlotDropsItsAttachmentToKeepVerificationAligned() {
        let attachments = [attachment("a.jpg"), attachment("b.jpg"), attachment("c.jpg")]

        let resolved = DraftMediaPreuploadResolution.merged(
            attachments,
            prepared: [nil, nil, reference("c.jpg")],
            uploaded: [reference("a.jpg")]
        )

        #expect(resolved.references.map(\.fileName) == ["a.jpg", "c.jpg"])
        #expect(resolved.attachments.map(\.id) == [attachments[0].id, attachments[2].id])
    }
}

@MainActor
private func settle(_ condition: () -> Bool) async {
    for _ in 0..<1_000 where !condition() {
        await Task.yield()
    }
}

private struct UploadCall: Hashable {
    let accountRef: String
    let fileName: String
    let cancelled: Bool
}

@MainActor
private final class UploadProbe {
    private(set) var calls: [UploadCall] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func uploader() -> DraftMediaPreuploads.Uploader {
        { [self] accountRef, attachment in
            record(UploadCall(accountRef: accountRef, fileName: attachment.fileName, cancelled: Task.isCancelled))
            return reference(attachment.fileName)
        }
    }

    func waitForCalls(_ count: Int) async {
        guard calls.count < count else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    private func record(_ call: UploadCall) {
        calls.append(call)
        let ready = waiters.filter { $0.count <= calls.count }
        waiters.removeAll { $0.count <= calls.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}

private func attachment(_ fileName: String) -> MediaDraftAttachment {
    MediaDraftAttachment(fileName: fileName, mediaType: "image/jpeg", data: Data(fileName.utf8), dim: nil)
}

private func reference(_ fileName: String, sourceEpoch: UInt64 = 1) -> MediaAttachmentReferenceFfi {
    MediaAttachmentReferenceFfi(
        locators: [MediaLocatorFfi(kind: "blossom-v1", value: "https://example.com/\(fileName)")],
        ciphertextSha256: String(repeating: "a", count: 64),
        plaintextSha256: String(repeating: "b", count: 64),
        nonceHex: String(repeating: "2", count: 24),
        fileName: fileName,
        mediaType: "image/jpeg",
        version: .v1,
        sourceEpoch: sourceEpoch,
        dim: nil,
        thumbhash: nil
    )
}

struct DraftMediaUploadPresentationTests {
    @Test(arguments: [
        (state: DraftMediaUploadState?.none, spinner: false),
        (state: DraftMediaUploadState?.some(.uploading), spinner: true),
        (state: DraftMediaUploadState?.some(.uploaded), spinner: false),
        (state: DraftMediaUploadState?.some(.failed), spinner: false),
    ])
    func onlyAnAttachmentStillUploadingShowsTheSpinner(state: DraftMediaUploadState?, spinner: Bool) {
        #expect(DraftMediaUploadPresentation.showsSpinner(for: state) == spinner)
    }

    @Test func uploadBadgeIsDeveloperOnly() {
        #expect(DraftMediaUploadPresentation.diagnosticBadge(for: .failed, showsDiagnostics: false) == nil)
        #expect(DraftMediaUploadPresentation.diagnosticBadge(for: .failed, showsDiagnostics: true) == .failed)
        #expect(DraftMediaUploadPresentation.diagnosticBadge(for: nil, showsDiagnostics: true) == nil)
    }
}
