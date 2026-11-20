import Foundation
import MarmotKit

extension MarmotClient {
    func approveOnboarding(accountID: String, revision: UInt64, recoveryEpoch: String?) async throws -> OnboardingSnapshotFfi {
        if let recoveryEpoch {
            return try await marmot.approveOnboardingRepairInEpoch(
                accountRef: accountID, revision: revision, recoveryEpoch: recoveryEpoch
            )
        }
        return try await marmot.approveOnboardingRepair(accountRef: accountID, revision: revision)
    }

    /// Persists a revision-bound preview only; it never signs or publishes.
    func proposeOnboardingRelayRepair(accountID: String, step: OnboardingStepFfi) async throws -> OnboardingSnapshotFfi {
        try await marmot.proposeOnboardingRelayRepair(accountRef: accountID, step: step)
    }

    func acknowledgeOnboarding(accountID: String, revision: UInt64, recoveryEpoch: String?) async throws -> OnboardingSnapshotFfi {
        if let recoveryEpoch {
            return try await marmot.acknowledgeOnboardingSingleDeviceInEpoch(
                accountRef: accountID, revision: revision, recoveryEpoch: recoveryEpoch
            )
        }
        return try await marmot.acknowledgeOnboardingSingleDevice(accountRef: accountID, revision: revision)
    }

    func onboardingRecoveryRequired(accountRef: String) async throws -> Bool {
        try await Task.detached(priority: .utility) { [marmot] in
            try marmot.onboardingRecoveryRequired(accountRef: accountRef)
        }.value
    }

    func recoverOnboarding(accountRef: String) async throws -> String {
        try await marmot.recoverOnboarding(accountRef: accountRef, acknowledgeLatestOnlyEvidence: true)
    }

    /// Durable local reads; no network I/O.
    func historyNotices(accountRef: String) async throws -> [HistoryNoticeFfi] {
        try await marmot.historyNotices(accountRef: accountRef)
    }

    /// False for a stale id: re-read the list.
    func dismissHistoryNotice(accountRef: String, noticeId: String) async throws -> Bool {
        try await marmot.dismissHistoryNotice(accountRef: accountRef, noticeId: noticeId)
    }

    func groupRecoveryStatus(accountRef: String, groupIdHex: String) async throws -> GroupRecoveryStatusFfi {
        try await marmot.groupRecoveryStatus(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func confirmGroupRejoin(accountRef: String, offer: GroupRejoinInvitationFfi) async throws -> GroupRecoveryStatusFfi {
        try await marmot.confirmGroupRejoin(
            accountRef: accountRef, welcomeIdHex: offer.welcomeIdHex, localStateToken: offer.localStateToken
        )
    }

    func declineGroupRejoin(accountRef: String, welcomeIdHex: String) async throws {
        try await marmot.declineGroupRejoin(accountRef: accountRef, welcomeIdHex: welcomeIdHex)
    }

    func presentedChatList(accountRef: String, includeArchived: Bool) async throws -> PresentedChatListSnapshotFfi {
        try await marmot.presentedChatList(accountRef: accountRef, includeArchived: includeArchived)
    }

    func presentedChatListRow(accountRef: String, groupIdHex: String) async throws -> PresentedChatRowFfi? {
        try await marmot.presentedChatListRow(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func openChatListWindow(accountRef: String, view: ChatListViewFfi) async throws -> ChatListWindowSubscription {
        try await marmot.openChatListWindow(accountRef: accountRef, view: view, initialRows: 50)
    }

    func openConversationWindow(accountRef: String, groupIdHex: String,
                                mode: ConversationOpenModeFfi = .automatic,
                                messageIdHex: String? = nil) async throws -> ConversationWindowSubscription {
        try await marmot.openConversationWindow(accountRef: accountRef, groupIdHex: groupIdHex,
            mode: mode, messageIdHex: messageIdHex, initialRows: 50, timeoutMs: 0)
    }

    func selectedMessageDraft(accountRef: String, groupIdHex: String) async throws -> SelectedMessageDraftFfi {
        try await Task.detached(priority: .utility) { [marmot] in
            try marmot.selectedMessageDraft(accountRef: accountRef, groupIdHex: groupIdHex)
        }.value
    }

    /// Saves `snapshot`, keeping each attachment MDK holds as a file by its
    /// id (`retainedIDs`) and leaving out large ones it doesn't hold yet.
    func saveMessageDraftIfRevision(accountRef: String, revision: MessageDraftRevisionFfi,
        snapshot: ConversationDraftSnapshot, retainedIDs: Set<String> = []) async throws -> SelectedMessageDraftFfi {
        let attachments = MessageDraftAttachmentInputs.inputs(for: snapshot.mediaAttachments, retainedIDs: retainedIDs)
        return try await Task.detached(priority: .utility) { [marmot] in
            try marmot.saveMessageDraftInputsIfRevision(accountRef: accountRef, revision: revision,
                content: snapshot.canonicalText, replyToMessageIdHex: snapshot.replyToMessageIdHex,
                mediaAttachments: attachments)
        }.value
    }

    /// Copies `attachment` into the account's encrypted media store as a
    /// file-backed attachment of the draft `revision` selects.
    func stageMessageDraftAttachment(accountRef: String, revision: MessageDraftRevisionFfi,
        attachment: MediaDraftAttachment, control: MediaFileTransferControlFfi) async throws -> SelectedMessageDraftFfi {
        let sources = try await MediaUploadSourceFiles.stage([attachment])
        do {
            let selected = try await marmot.stageMessageDraftAttachmentFile(accountRef: accountRef, revision: revision,
                request: MessageDraftAttachmentInputs.fileRequest(for: attachment, sourcePath: sources.urls[0].path),
                control: control)
            await sources.remove()
            return selected
        } catch {
            await sources.remove()
            throw error
        }
    }

    func clearMessageDraftIfRevision(accountRef: String, revision: MessageDraftRevisionFfi) async throws -> SelectedMessageDraftFfi {
        try await Task.detached(priority: .utility) { [marmot] in
            try marmot.clearMessageDraftIfRevision(accountRef: accountRef, revision: revision)
        }.value
    }

    func hydrateSelectedDraft(accountRef: String, selected: SelectedMessageDraftFfi) async throws -> MessageDraftFfi? {
        guard let draft = selected.draft else { return nil }
        var attachments: [MessageDraftAttachmentFfi] = []
        for item in draft.mediaAttachments {
            let bytes: Data
            if item.fileBacked {
                // Mapped from a private copy, never resident: it can be 512 MiB.
                // Written off the MainActor, where this async method would otherwise run.
                let copy = Task.detached(priority: .utility) { [marmot] in
                    try await PickedMediaFile.mappedData(expectedSize: item.plaintextSize) { offset in
                        try await marmot.readMessageDraftAttachment(accountRef: accountRef, revision: selected.revision,
                            attachmentId: item.id, offset: offset, limit: MessageDraftAttachmentInputs.readChunkBytes)
                    }
                }
                // Leaving the chat stops the copy and removes the partial file.
                bytes = try await withTaskCancellationHandler { try await copy.value } onCancel: { copy.cancel() }
            } else {
                let inline = try await Task.detached(priority: .utility) { [marmot] in
                    try marmot.messageDraftAttachmentIfRevision(accountRef: accountRef,
                        revision: selected.revision, attachmentId: item.id)
                }.value
                guard let inline else {
                    throw MarmotKitError.InvalidMessageDraft(details: "Draft attachment is unavailable.")
                }
                bytes = inline
            }
            attachments.append(MessageDraftAttachmentFfi(id: item.id, fileName: item.fileName, mediaType: item.mediaType,
                plaintext: bytes, dim: item.dim, thumbhash: item.thumbhash,
                durationSeconds: item.durationSeconds, waveformSamples: item.waveformSamples))
        }
        return MessageDraftFfi(groupIdHex: draft.groupIdHex, content: draft.content,
            replyToMessageIdHex: draft.replyToMessageIdHex, mediaAttachments: attachments,
            createdAtMs: draft.createdAtMs, updatedAtMs: draft.updatedAtMs)
    }

    func sendMessageDraft(accountRef: String, revision: MessageDraftRevisionFfi,
        attachments: [MediaAttachmentReferenceFfi]) async throws -> SendSummaryFfi {
        try await marmot.sendMessageDraft(accountRef: accountRef, revision: revision, attachments: attachments)
    }

    func subscribeAccountAttention() async throws -> AccountAttentionSubscription {
        try await marmot.subscribeAccountAttention()
    }

    func forgetGroupLocal(accountRef: String, groupIdHex: String) async throws -> Bool {
        try await marmot.forgetGroupLocal(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func openPresentedChatList(accountRef: String, includeArchived: Bool) async throws -> PresentedChatListSubscription {
        try await marmot.openPresentedChatList(accountRef: accountRef, includeArchived: includeArchived)
    }

    func presentedChatListSubscriptionSnapshot(_ subscription: PresentedChatListSubscription) async -> PresentedChatListUpdateFfi? {
        await Task.detached(priority: .utility) { subscription.snapshot() }.value
    }
}
