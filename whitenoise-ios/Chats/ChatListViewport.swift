import SwiftUI
import MarmotKit

/// Retains the visible row's pixel offset while MDK replaces a bounded window.
@MainActor
final class ChatListViewport {
    private final class WeakRow {
        weak var view: ChatListAnchorView?
        init(_ view: ChatListAnchorView) { self.view = view }
    }
    private struct Pending {
        let groupId: String?
        let offset: CGFloat
        let sequence: UInt64
    }

    private var rows: [String: WeakRow] = [:]
    private weak var scrollView: UIScrollView?
    private var pending: Pending?
    private var isRestoring = false
    private var programmaticScroll: UUID?

    func beginProgrammaticScroll() -> UUID {
        let token = UUID()
        programmaticScroll = token
        pending = nil
        return token
    }

    func endProgrammaticScroll(_ token: UUID) {
        if programmaticScroll == token { programmaticScroll = nil }
    }
    private var topRequested = false

    func requestTop() {
        topRequested = true
        if let scrollView {
            scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: -scrollView.adjustedContentInset.top), animated: false)
        }
    }

    func register(_ view: ChatListAnchorView) {
        rows = rows.filter { $0.value.view?.groupId == $0.key }
        rows[view.groupId] = WeakRow(view)
        var ancestor = view.superview
        while let current = ancestor {
            if let scroll = current as? UIScrollView { scrollView = scroll; break }
            ancestor = current.superview
        }
        restoreIfReady(from: view)
    }

    func visibleAnchor() -> String? { visibleRow()?.id }

    private func visibleRow() -> (id: String, offset: CGFloat)? {
        guard let scrollView else { return nil }
        let top = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        let bottom = scrollView.contentOffset.y + scrollView.bounds.height - scrollView.adjustedContentInset.bottom
        return rows.compactMap { id, row -> (id: String, offset: CGFloat)? in
            guard let view = row.view, view.window != nil else { return nil }
            let rect = view.convert(view.bounds, to: scrollView)
            guard rect.maxY > top, rect.minY < bottom else { return nil }
            return (id, rect.minY - top)
        }.min { $0.offset < $1.offset }
    }

    func prepare(for snapshot: ChatListWindowSnapshotFfi) {
        prepare(anchor: snapshot.anchor, sequence: snapshot.sequence)
    }

    func cancelRestoration() { pending = nil }

    func prepare(for snapshot: ConversationWindowSnapshotFfi, displayID: (String) -> String = { "msg:" + $0 }) {
        guard let index = snapshot.anchor.index, snapshot.messages.indices.contains(Int(index)) else { return }
        let id = displayID(snapshot.messages[Int(index)].timeline.messageIdHex)
        // Initial positioning belongs to the conversation scroll coordinator.
        guard !rows.isEmpty else { return }
        let anchor: ChatListAnchorOutcomeFfi
        switch snapshot.anchor.kind {
        case .recoveredNext, .recoveredPrevious: anchor = .recovered(groupIdHex: id, index: index)
        default:
            guard let visible = visibleRow(), snapshot.messages.contains(where: { displayID($0.timeline.messageIdHex) == visible.id }) else {
                anchor = .recovered(groupIdHex: id, index: index)
                prepare(anchor: anchor, sequence: snapshot.revision.sequence)
                return
            }
            anchor = .retained(groupIdHex: visible.id, index: index)
        }
        prepare(anchor: anchor, sequence: snapshot.revision.sequence)
    }

    private func prepare(anchor: ChatListAnchorOutcomeFfi, sequence: UInt64) {
        guard programmaticScroll == nil, let scrollView, !scrollView.isTracking, !scrollView.isDragging, !scrollView.isDecelerating else {
            pending = nil
            return
        }
        let visible = visibleRow()
        switch anchor {
        case .top:
            pending = Pending(
                groupId: topRequested ? nil : visible?.id,
                offset: topRequested ? 0 : visible?.offset ?? 0,
                sequence: sequence
            )
            topRequested = false
        case .reset:
            pending = Pending(groupId: nil, offset: 0, sequence: sequence)
        case .recovered(let id, _):
            pending = Pending(groupId: id, offset: visible?.offset ?? 0, sequence: sequence)
        case .retained(let id, _):
            let top = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
            let offset = rows[id]?.view.map { $0.convert($0.bounds, to: scrollView).minY - top }
            pending = Pending(groupId: id, offset: offset ?? visible?.offset ?? 0, sequence: sequence)
        }
    }

    func reset() { pending = nil; programmaticScroll = nil; topRequested = false; rows = [:]; scrollView = nil }

    private func restoreIfReady(from view: ChatListAnchorView) {
        guard !isRestoring, let pending, pending.sequence == view.sequence,
              pending.groupId == nil || pending.groupId == view.groupId,
              let scrollView, view.window != nil else { return }
        guard !scrollView.isTracking, !scrollView.isDragging, !scrollView.isDecelerating else {
            self.pending = nil
            return
        }
        isRestoring = true
        defer { isRestoring = false }
        let insets = scrollView.adjustedContentInset
        let target: CGFloat
        if pending.groupId == nil {
            target = -insets.top
        } else {
            let rect = view.convert(view.bounds, to: scrollView)
            target = rect.minY - insets.top - pending.offset
        }
        let maximum = max(-insets.top, scrollView.contentSize.height - scrollView.bounds.height + insets.bottom)
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: min(maximum, max(-insets.top, target))), animated: false)
        self.pending = nil
    }
}

final class ChatListAnchorView: UIView {
    var groupId = ""
    var sequence: UInt64 = 0
    weak var viewport: ChatListViewport?

    override func layoutSubviews() {
        super.layoutSubviews()
        viewport?.register(self)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsLayout()
    }
}

struct ChatListRowAnchor: UIViewRepresentable {
    let groupId: String
    let sequence: UInt64
    let viewport: ChatListViewport

    func makeUIView(context: Context) -> ChatListAnchorView {
        let view = ChatListAnchorView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: ChatListAnchorView, context: Context) {
        view.groupId = groupId
        view.sequence = sequence
        view.viewport = viewport
        view.setNeedsLayout()
    }
}
