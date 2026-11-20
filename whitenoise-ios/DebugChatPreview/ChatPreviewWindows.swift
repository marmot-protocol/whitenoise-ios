#if DEBUG
import Foundation
import MarmotKit

@MainActor
final class ChatPreviewWindows: ConversationProjectionClient {
    private(set) var chats: [ChatPreviewThread]
    enum OpenScenario { case slow, failed }
    var openScenarios: [String: OpenScenario] = [:]
    var onChange: (([ChatPreviewThread]) -> Void)?
    private var active: [String: ChatPreviewWindow] = [:]

    init(chats: [ChatPreviewThread]) { self.chats = chats }

    func change(_ id: String, _ update: (inout ChatPreviewThread) -> Void) {
        guard let index = chats.firstIndex(where: { $0.id == id }) else { return }
        update(&chats[index])
        active[id]?.replace(with: chats[index].snapshot)
        onChange?(chats)
    }

    func openConversationWindowFeed(accountRef: String, groupIdHex: String, mode: ConversationOpenModeFfi,
                                    messageIdHex: String?) async throws -> any ConversationWindowFeed {
        guard accountRef == "preview" else {
            throw CancellationError()
        }
        switch openScenarios[groupIdHex] {
        case .slow:
            openScenarios[groupIdHex] = nil
            try await Task.sleep(for: .seconds(1))
        case .failed:
            throw CocoaError(.fileReadUnknown)
        case nil: break
        }
        guard let thread = chats.first(where: { $0.id == groupIdHex }) else { throw CancellationError() }
        let target = messageIdHex ?? (mode == .automatic ? thread.row.row.firstUnreadMessageIdHex : nil)
        let window = try ChatPreviewWindow(snapshot: thread.snapshot, target: target, isUnread: mode == .automatic && messageIdHex == nil)
        active[groupIdHex] = window
        return window
    }
}

/// A window owned by one open screen. Only Swift values cross this boundary.
@MainActor
private final class ChatPreviewWindow: ConversationWindowFeed {
    private nonisolated let initial: ConversationWindowSnapshotFfi
    private let updates: AsyncStream<ConversationWindowSnapshotFfi>
    private let continuation: AsyncStream<ConversationWindowSnapshotFfi>.Continuation
    private var history: [ConversationMessageFfi]
    private var bounds: Range<Int>
    private static let pageSize = 60
    private static let maximumRows = 200
    private var current: ConversationWindowSnapshotFfi
    private var closed = false

    init(snapshot: ConversationWindowSnapshotFfi, target: String?, isUnread: Bool) throws {
        var snapshot = snapshot
        let rows = snapshot.messages
        let targetIndex = target.flatMap { id in rows.firstIndex { $0.timeline.messageIdHex == id } }
        if target != nil && targetIndex == nil { throw MarmotKitError.ConversationWindowMessageNotRetained }
        let start = Self.start(around: targetIndex, count: rows.count, budget: Self.pageSize)
        let range = start..<min(rows.count, start + Self.pageSize)
        snapshot.messages = Array(rows[range])
        snapshot.hasMoreBefore = start > 0
        snapshot.hasMoreAfter = range.upperBound < rows.count
        if let index = targetIndex {
            snapshot.anchor = .init(kind: isUnread ? .firstUnread : .message, index: UInt32(index - start))
        } else {
            snapshot.anchor = .init(kind: rows.isEmpty ? .empty : .latest, index: snapshot.messages.indices.last.map(UInt32.init))
        }
        history = rows
        bounds = range
        initial = snapshot
        current = snapshot
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    nonisolated func snapshot() -> ConversationWindowSnapshotFfi? { initial }

    @MainActor func nextCancellable() async throws -> ConversationWindowSnapshotFfi? {
        for await update in updates { return update }
        try Task.checkCancellation()
        return nil
    }

    @MainActor func cancel() async {
        closed = true
        continuation.finish()
    }

    @MainActor func setVisibleAnchor(revision: ConversationWindowRevisionFfi, messageIdHex: String,
                          timeoutMs: UInt32) throws -> ConversationWindowSnapshotFfi {
        try move(revision, id: messageIdHex, kind: .retained)
    }

    @MainActor func jumpToMessage(revision: ConversationWindowRevisionFfi, messageIdHex: String,
                       timeoutMs: UInt32) throws -> ConversationWindowSnapshotFfi {
        try move(revision, id: messageIdHex, kind: .message)
    }

    @MainActor func returnToLatest(revision: ConversationWindowRevisionFfi, timeoutMs: UInt32) throws -> ConversationWindowSnapshotFfi {
        try move(revision, id: history.last?.timeline.messageIdHex, kind: .latest)
    }

    @MainActor func page(revision: ConversationWindowRevisionFfi, direction: ConversationPageDirectionFfi,
              count: UInt32, timeoutMs: UInt32) throws -> ConversationWindowSnapshotFfi {
        try validate(revision)
        let step = max(1, min(Int(count), Self.maximumRows))
        let anchorIndex = current.anchor.index.map { bounds.lowerBound + Int($0) }
        var start = bounds.lowerBound
        var end = bounds.upperBound
        switch direction {
        case .older:
            start = max(0, start - step)
            end = min(end, start + Self.maximumRows)
        case .newer:
            end = min(history.count, end + step)
            start = max(start, end - Self.maximumRows)
        }
        let range = start..<end
        if let anchorIndex, !range.isEmpty {
            // A search can page beyond the old viewport without scrolling it first.
            let kept = min(max(anchorIndex, start), end - 1)
            install(range, anchor: history[kept].timeline.messageIdHex,
                    kind: kept == anchorIndex ? current.anchor.kind : .retained)
        } else {
            install(range, anchor: nil, kind: .empty)
        }
        return current
    }

    func replace(with snapshot: ConversationWindowSnapshotFfi) {
        guard !closed else { return }
        let followsTail = current.anchor.kind == .latest || current.anchor.kind == .empty
        let anchor = current.anchor.index.map { current.messages[Int($0)].timeline.messageIdHex }
        let budget = max(Self.pageSize, bounds.count)
        history = snapshot.messages
        current.readState = snapshot.readState
        let start = followsTail ? max(0, history.count - budget) : min(bounds.lowerBound, max(0, history.count - budget))
        let range = start..<min(history.count, start + budget)
        install(range, anchor: followsTail ? history.last?.timeline.messageIdHex
                : anchor.flatMap { id in history[range].contains(where: { $0.timeline.messageIdHex == id }) ? id : nil }
                    ?? history[range].first?.timeline.messageIdHex,
                kind: followsTail ? .latest : current.anchor.kind)
        continuation.yield(current)
    }

    private func validate(_ revision: ConversationWindowRevisionFfi) throws {
        guard !closed else { throw CancellationError() }
        guard current.revision == revision else { throw MarmotKitError.ConversationWindowStale }
    }

    private func move(_ revision: ConversationWindowRevisionFfi, id: String?,
                      kind: ConversationAnchorKindFfi) throws -> ConversationWindowSnapshotFfi {
        try validate(revision)
        let target = id.flatMap { key in history.firstIndex { $0.timeline.messageIdHex == key } }
        if id != nil, target == nil { throw MarmotKitError.ConversationWindowMessageNotRetained }
        let newBounds: Range<Int>
        if kind == .retained, let target, bounds.contains(target) {
            newBounds = bounds
        } else {
            let budget = max(Self.pageSize, bounds.count)
            let start = Self.start(around: kind == .latest ? nil : target, count: history.count, budget: budget)
            newBounds = start..<min(start + budget, history.count)
        }
        install(newBounds, anchor: id, kind: kind)
        return current
    }

    private static func start(around index: Int?, count: Int, budget: Int) -> Int {
        let lastStart = max(0, count - budget)
        return index.map { min(lastStart, max(0, $0 - budget / 2)) } ?? lastStart
    }

    private func install(_ range: Range<Int>, anchor: String?, kind: ConversationAnchorKindFfi) {
        bounds = range
        current.messages = Array(history[range])
        let index = anchor.flatMap { key in current.messages.firstIndex { $0.timeline.messageIdHex == key } }
        current.anchor = .init(kind: index == nil ? .empty : kind, index: index.map(UInt32.init))
        current.hasMoreBefore = range.lowerBound > 0
        current.hasMoreAfter = range.upperBound < history.count
        current.revision.sequence += 1
    }
}
#endif
