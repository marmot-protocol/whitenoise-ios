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

    func saveMessageDraftIfRevision(accountRef: String, revision: MessageDraftRevisionFfi,
        snapshot: ConversationDraftSnapshot) async throws -> SelectedMessageDraftFfi {
        let attachments = snapshot.mediaAttachments.map(\.messageDraftAttachment)
        return try await Task.detached(priority: .utility) { [marmot] in
            try marmot.saveMessageDraftIfRevision(accountRef: accountRef, revision: revision,
                content: snapshot.canonicalText, replyToMessageIdHex: snapshot.replyToMessageIdHex,
                mediaAttachments: attachments)
        }.value
    }

    func clearMessageDraftIfRevision(accountRef: String, revision: MessageDraftRevisionFfi) async throws -> SelectedMessageDraftFfi {
        try await Task.detached(priority: .utility) { [marmot] in
            try marmot.clearMessageDraftIfRevision(accountRef: accountRef, revision: revision)
        }.value
    }

    func hydrateSelectedDraft(accountRef: String, selected: SelectedMessageDraftFfi) async throws -> MessageDraftFfi? {
        try await Task.detached(priority: .utility) { [marmot] in
            guard let draft = selected.draft else { return nil }
            let attachments = try draft.mediaAttachments.map { item in
                guard let bytes = try marmot.messageDraftAttachmentIfRevision(accountRef: accountRef,
                    revision: selected.revision, attachmentId: item.id) else {
                    throw MarmotKitError.InvalidMessageDraft(details: "Draft attachment is unavailable.")
                }
                return MessageDraftAttachmentFfi(id: item.id, fileName: item.fileName, mediaType: item.mediaType,
                    plaintext: bytes, dim: item.dim, thumbhash: item.thumbhash,
                    durationSeconds: item.durationSeconds, waveformSamples: item.waveformSamples)
            }
            return MessageDraftFfi(groupIdHex: draft.groupIdHex, content: draft.content,
                replyToMessageIdHex: draft.replyToMessageIdHex, mediaAttachments: attachments,
                createdAtMs: draft.createdAtMs, updatedAtMs: draft.updatedAtMs)
        }.value
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
