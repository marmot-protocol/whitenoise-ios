import MarmotKit

/// Chat-list side of MDK 0.13's pending-send draft handoff.
nonisolated enum ChatListDraftHandoff {
    /// Whether a send that captured `sentRevision` covers the row's draft
    /// preview: MDK says the row's draft is that submitted revision or an older
    /// one, so the row shows the pending outgoing message instead. A newer edit
    /// (even with identical text), a recreated draft, another store or group,
    /// or missing metadata keeps the draft visible. Presentation only; this
    /// never authorizes clearing a draft.
    static func coversDraftPreview(
        _ preview: SelectedChatPreviewFfi?,
        draftVersion: ChatListDraftVersionFfi?,
        sentRevision: MessageDraftRevisionFfi?
    ) -> Bool {
        guard case .draft? = preview, let draftVersion, let sentRevision else { return false }
        return sentRevision.includesChatListVersion(version: draftVersion)
    }
}
