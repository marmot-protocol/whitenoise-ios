import MarmotKit

#if DEBUG

/// The retained window consumed by the conversation, including viewport commands.
nonisolated protocol ConversationWindowFeed: AnyObject, Sendable {
    func snapshot() -> ConversationWindowSnapshotFfi?
    func nextCancellable() async throws -> ConversationWindowSnapshotFfi?
    func setVisibleAnchor(revision: ConversationWindowRevisionFfi, messageIdHex: String,
                          timeoutMs: UInt32) async throws -> ConversationWindowSnapshotFfi
    func returnToLatest(revision: ConversationWindowRevisionFfi,
                        timeoutMs: UInt32) async throws -> ConversationWindowSnapshotFfi
    func jumpToMessage(revision: ConversationWindowRevisionFfi, messageIdHex: String,
                       timeoutMs: UInt32) async throws -> ConversationWindowSnapshotFfi
    func page(revision: ConversationWindowRevisionFfi, direction: ConversationPageDirectionFfi,
              count: UInt32, timeoutMs: UInt32) async throws -> ConversationWindowSnapshotFfi
    /// Ends outstanding reads before the view model replaces this feed.
    func cancel() async
}

nonisolated extension ConversationWindowSubscription: ConversationWindowFeed {}

protocol ConversationProjectionClient: AnyObject {
    func openConversationWindowFeed(accountRef: String, groupIdHex: String,
                                    mode: ConversationOpenModeFfi, messageIdHex: String?) async throws
        -> any ConversationWindowFeed
}

extension MarmotClient: ConversationProjectionClient {
    func openConversationWindowFeed(accountRef: String, groupIdHex: String,
                                    mode: ConversationOpenModeFfi, messageIdHex: String?) async throws
        -> any ConversationWindowFeed {
        try await openConversationWindow(accountRef: accountRef, groupIdHex: groupIdHex,
                                         mode: mode, messageIdHex: messageIdHex)
    }
}

typealias ActiveConversationWindow = any ConversationWindowFeed
#else
typealias ActiveConversationWindow = ConversationWindowSubscription
#endif
