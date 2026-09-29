import Testing
import Foundation
@testable import whitenoise_ios
@testable import MarmotKit

struct SendDispatchAndCancellationTests {

    /// #49 — send() must confirm it has a view model before clearing the draft,
    /// otherwise a nil view model at dispatch time silently discards the message.
    @MainActor
    @Test func sendPreparationKeepsDraftWhenViewModelIsMissing() {
        var draft = "hello"
        var attachments: [MediaDraftAttachment] = []

        let payload = ConversationSendPreparation.prepare(
            draft: &draft,
            mediaDrafts: &attachments,
            viewModel: nil
        )

        #expect(payload == nil)
        #expect(draft == "hello")
        #expect(attachments.isEmpty)
    }

    /// #76 — push registration must treat CancellationError as a non-failure and
    /// not surface it as "Push registration failed".
    @Test func pushRegistrationIgnoresCancellation() {
        #expect(NativePushRegistrationErrorDisposition.disposition(for: CancellationError()) == .stopSync)
        #expect(NativePushRegistrationErrorDisposition.disposition(
            for: NotificationSettingsActionError.missingApnsToken
        ) == .stopSync)
        #expect(NativePushRegistrationErrorDisposition.disposition(for: NativePushTestError.generic) == .recordFailure)
    }

    /// #350 — native push registration reconciliation is best-effort and may
    /// run before the Keychain-backed runtime can be rebuilt. A transient
    /// runtime rebuild failure must skip this pass instead of trapping.
    @Test func nativePushEnabledAccountRefsSkipsWhenRuntimeRebuildFails() async {
        let accountRefs = await AppState.nativePushEnabledAccountRefs(accountRefs: ["account-a"]) {
            throw NativePushTestError.generic
        }

        #expect(accountRefs.isEmpty)
    }

    @MainActor
    @Test func preStagingValidationRemovesOnlyTheOversizedAttachments() {
        let small = attachment(bytes: 1_024)
        let oversizedDocument = attachment(bytes: MediaDraftProcessor.maxAttachmentBytes + 1)
        let oversizedImage = attachment(bytes: MediaDraftProcessor.maxImageAttachmentBytes + 1, mediaType: "image/jpeg")
        let largeDocument = attachment(bytes: MediaDraftProcessor.maxImageAttachmentBytes + 1)
        var drafts = [small, oversizedDocument, oversizedImage, largeDocument]

        let rejection = ConversationSendPreparation.removeOversizedAttachments(from: &drafts)

        #expect(rejection == .attachments([oversizedDocument.id, oversizedImage.id]))
        #expect(drafts.map(\.id) == [small.id, largeDocument.id])
    }

    @MainActor
    @Test func preStagingValidationLeavesAttachmentsWithinTheLimitAlone() {
        var drafts = [attachment(bytes: MediaDraftProcessor.maxAttachmentBytes)]
        let before = drafts

        #expect(ConversationSendPreparation.removeOversizedAttachments(from: &drafts) == nil)
        #expect(drafts == before)
    }

    @Test func serverSizeRejectionOfASingleUploadIdentifiesThatAttachment() {
        let only = attachment(bytes: 1_024)
        let error = MarmotKitError.Runtime(details: "upload returned HTTP 413: File too large")

        #expect(OutgoingSendSizePolicy.rejection(for: error, phase: .upload(candidates: [only])) == .attachments([only.id]))
    }

    @Test func serverSizeRejectionOfSeveralUploadsDoesNotGuessWhichAttachment() {
        let error = MarmotKitError.Runtime(details: "upload returned HTTP 413")
        let candidates = [attachment(bytes: 1_024), attachment(bytes: 2_048)]

        #expect(OutgoingSendSizePolicy.rejection(for: error, phase: .upload(candidates: candidates)) == .unidentifiedAttachment)
    }

    @Test func locallyOversizedUploadIsIdentifiedWhateverTheServerSaid() {
        let fine = attachment(bytes: 1_024)
        let oversized = attachment(bytes: MediaDraftProcessor.maxAttachmentBytes + 1)
        let error = MarmotKitError.Runtime(details: "relay disconnected")

        #expect(OutgoingSendSizePolicy.rejection(for: error, phase: .upload(candidates: [fine, oversized])) == .attachments([oversized.id]))
    }

    @Test func sizeRejectionAtAdmissionIsATextError() {
        let error = MarmotKitError.Publish(details: "event too large")

        #expect(OutgoingSendSizePolicy.rejection(for: error, phase: .admission) == .text)
    }

    @Test func unrelatedFailuresAreNotSizeRejections() {
        let relay = MarmotKitError.Runtime(details: "relay disconnected")
        let foreign = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "too large"])

        #expect(OutgoingSendSizePolicy.rejection(for: relay, phase: .admission) == nil)
        #expect(OutgoingSendSizePolicy.rejection(for: relay, phase: .upload(candidates: [attachment(bytes: 1)])) == nil)
        #expect(OutgoingSendSizePolicy.rejection(for: foreign, phase: .admission) == nil)
    }

    @Test func onlyMessageLengthDiagnosticsCountAsTextTooLong() {
        let unrelated = ["relay hint too long", "group id too long", "push token is too long for marmot-push-v1"]
        for details in unrelated {
            #expect(OutgoingSendSizePolicy.rejection(for: MarmotKitError.Runtime(details: details), phase: .admission) == nil)
        }
        #expect(OutgoingSendSizePolicy.rejection(
            for: MarmotKitError.Publish(details: "message too long"), phase: .admission
        ) == .text)
    }

    @Test func attachmentRejectionRestoresTextAndTheOtherAttachments() {
        let kept = attachment(bytes: 1_024)
        let rejected = attachment(bytes: 2_048)
        let tapped = ConversationComposerContents(draft: "caption", mediaDrafts: [kept, rejected], replyTargetMessageIdHex: nil)

        let restored = ConversationSendRecovery.restoredContents(
            after: .attachments([rejected.id]),
            tapped: tapped,
            current: emptyComposer,
            isEditing: false
        )

        #expect(restored == ConversationComposerContents(draft: "caption", mediaDrafts: [kept], replyTargetMessageIdHex: nil))
    }

    @Test func textRejectionRestoresEverythingIncludingTheReplyTarget() {
        let photo = attachment(bytes: 1_024)
        let tapped = ConversationComposerContents(draft: "long text", mediaDrafts: [photo], replyTargetMessageIdHex: "reply")

        for rejection in [OutgoingSendSizeRejection.text, .unidentifiedAttachment] {
            let restored = ConversationSendRecovery.restoredContents(
                after: rejection,
                tapped: tapped,
                current: emptyComposer,
                isEditing: false
            )
            #expect(restored == tapped)
        }
    }

    @Test func recoveryNeverOverwritesEditsMadeWhileTheSendWasInFlight() {
        let rejected = attachment(bytes: 1_024)
        let tapped = ConversationComposerContents(draft: "caption", mediaDrafts: [rejected], replyTargetMessageIdHex: nil)
        let edits = [
            ConversationComposerContents(draft: "newer", mediaDrafts: [], replyTargetMessageIdHex: nil),
            ConversationComposerContents(draft: "", mediaDrafts: [attachment(bytes: 1)], replyTargetMessageIdHex: nil),
            ConversationComposerContents(draft: "", mediaDrafts: [], replyTargetMessageIdHex: "reply"),
        ]

        for current in edits {
            #expect(ConversationSendRecovery.restoredContents(
                after: .attachments([rejected.id]), tapped: tapped, current: current, isEditing: false
            ) == nil)
        }
        #expect(ConversationSendRecovery.restoredContents(
            after: .text, tapped: tapped, current: emptyComposer, isEditing: true
        ) == nil)
    }

    @Test func attachmentOnlySendHasNothingToRestore() {
        let rejected = attachment(bytes: 1_024)
        let tapped = ConversationComposerContents(draft: "", mediaDrafts: [rejected], replyTargetMessageIdHex: nil)

        #expect(ConversationSendRecovery.restoredContents(
            after: .attachments([rejected.id]), tapped: tapped, current: emptyComposer, isEditing: false
        ) == nil)
    }

    @Test func noticeNamesTheCauseAndWhereTheMessageWent() {
        #expect(ConversationSendRecovery.notice(for: .text, restored: true).title == "Message too long")
        #expect(ConversationSendRecovery.notice(for: .attachments([]), restored: true).title == "Attachment too large")
        #expect(ConversationSendRecovery.notice(for: .unidentifiedAttachment, restored: false).message
            == "Your message was kept in the failed bubble.")
    }

    @MainActor
    @Test func composerSendReportsADefinitiveTextSizeRejectionInsteadOfTheGenericToast() async throws {
        let client = try MarmotClient.testClient()
        let appState = AppState(client: client)
        appState.activeAccountRef = "account-ref"
        let store = TimelineStore(appState: appState, groupIdHex: groupId)
        let composer = ComposerModel(appState: appState, groupIdHex: groupId, timelineStore: store)
        composer.canSendMessages = { true }
        composer.localSendStatusForTesting = { _ in .rejected }
        composer.sendTextForTesting = { _, _, _, _, _ in throw MarmotKitError.Publish(details: "event too large") }

        let staged = try #require(composer.stage(text: "hello", reportsSizeRejection: true))
        let rejection = await composer.submit(staged)

        #expect(rejection == .text)
        #expect(store.failedTransientRecord(rowId: "msg:\(staged.tempId)")?.plaintext == "hello")
        #expect(appState.activeToast == nil)
        try await client.marmot.shutdownAndClose()
    }

    @MainActor
    @Test func sendsOutsideTheComposerKeepTheGenericFailureToast() async throws {
        let client = try MarmotClient.testClient()
        let appState = AppState(client: client)
        appState.activeAccountRef = "account-ref"
        let store = TimelineStore(appState: appState, groupIdHex: groupId)
        let composer = ComposerModel(appState: appState, groupIdHex: groupId, timelineStore: store)
        composer.canSendMessages = { true }
        composer.localSendStatusForTesting = { _ in .rejected }
        composer.sendTextForTesting = { _, _, _, _, _ in throw MarmotKitError.Publish(details: "event too large") }

        let staged = try #require(composer.stage(text: "hello"))
        let rejection = await composer.submit(staged)

        #expect(rejection == nil)
        #expect(appState.activeToast?.title == "Send failed")
        try await client.marmot.shutdownAndClose()
    }

    @MainActor
    @Test func uncertainAdmissionIsNeverReportedAsARecoverableRejection() async throws {
        let client = try MarmotClient.testClient()
        let appState = AppState(client: client)
        appState.activeAccountRef = "account-ref"
        let store = TimelineStore(appState: appState, groupIdHex: groupId)
        let composer = ComposerModel(appState: appState, groupIdHex: groupId, timelineStore: store)
        composer.canSendMessages = { true }
        let statuses: [LocalSendStatusFfi?] = [nil, .queued]
        for status in statuses {
            composer.localSendStatusForTesting = { _ in status }
            composer.sendTextForTesting = { _, _, _, _, _ in
                if status == nil { throw MarmotKitError.AccountWorkerResponseTimedOut }
                throw MarmotKitError.Publish(details: "event too large")
            }

            let staged = try #require(composer.stage(text: "maybe sent", reportsSizeRejection: true))
            let rejection = await composer.submit(staged)

            #expect(rejection == nil)
            #expect(store.failedTransientRecord(rowId: "msg:\(staged.tempId)") == nil)
        }
        try await client.marmot.shutdownAndClose()
    }

    private let groupId = String(repeating: "aa", count: 32)

    private var emptyComposer: ConversationComposerContents {
        ConversationComposerContents(draft: "", mediaDrafts: [], replyTargetMessageIdHex: nil)
    }

    private func attachment(bytes: Int, mediaType: String = "application/pdf") -> MediaDraftAttachment {
        MediaDraftAttachment(
            fileName: mediaType == "application/pdf" ? "file.pdf" : "photo.jpg",
            mediaType: mediaType,
            data: Data(count: bytes),
            dim: nil
        )
    }

    private enum NativePushTestError: Error {
        case generic
    }
}
