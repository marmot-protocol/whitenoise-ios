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
        var retainedMinY: CGFloat?
        /// Set when the container lays out only the rows around its viewport.
        var lazy: LazyRestoration?
    }
    /// What finding the pending row takes once a lazy container has dropped it.
    private struct LazyRestoration {
        /// Row positions in the replacement.
        let order: [String: Int]
        /// The viewport's offset before it was first moved toward the row.
        let startOffset: CGFloat
        /// Where the viewport was last put; anything beyond it is the reader's own scrolling.
        var placedOffset: CGFloat
        /// The reader's scrolling before the viewport was last put somewhere.
        var travel: CGFloat = 0
        /// Estimated height of the rows landing above the pending row, until applied.
        var estimatedMove: CGFloat
        var searches = 0
        var isSearchScheduled = false

        /// Where to put a viewport now at `current` so it sits at `offset` plus the reader's scrolling.
        mutating func place(at offset: CGFloat, from current: CGFloat) -> CGFloat {
            travel += current - placedOffset
            placedOffset = offset + travel
            return placedOffset
        }
    }

    /// A row that is still not laid out after this many estimated moves is given up on.
    static let maximumRowSearches = 3
    private static let initialPruneThreshold = 128

    private var rows: [String: WeakRow] = [:]
    private var pruneThreshold = ChatListViewport.initialPruneThreshold
    private weak var scrollView: UIScrollView?
    private var pending: Pending?
    private var isRestoring = false
    private var programmaticScroll: UUID?

    var registeredRowCount: Int { rows.count }

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
        rows[view.groupId] = WeakRow(view)
        if rows.count >= pruneThreshold {
            pruneDeadRows()
        }
        var ancestor = view.superview
        while let current = ancestor {
            if let scroll = current as? UIScrollView { scrollView = scroll; break }
            ancestor = current.superview
        }
        // A lazy restoration for a window that has since been replaced can no longer be met.
        if let pending, pending.lazy != nil, view.sequence > pending.sequence { self.pending = nil }
        restoreIfReady(from: view)
        searchForPendingRowIfDropped(seenFrom: view)
    }

    func unregister(_ view: ChatListAnchorView, groupId: String) {
        if rows[groupId]?.view === view {
            rows.removeValue(forKey: groupId)
        }
    }

    private func pruneDeadRows() {
        rows = rows.filter { $0.value.view?.groupId == $0.key }
        pruneThreshold = max(Self.initialPruneThreshold, rows.count * 2)
    }

    func visibleAnchor() -> String? { visibleRow()?.id }

    /// Whether the container currently has this row in layout.
    func isLaidOut(_ rowID: String) -> Bool {
        guard let view = rows[rowID]?.view, view.groupId == rowID else { return false }
        return view.window != nil
    }

    var visibleFrameInWindow: CGRect? {
        guard let scrollView, let window = scrollView.window else { return nil }
        let visible = scrollView.bounds.inset(by: scrollView.adjustedContentInset)
        let frame = scrollView.convert(visible, to: window).intersection(window.safeAreaLayoutGuide.layoutFrame)
        return frame.isEmpty ? nil : frame
    }

    private func visibleRows() -> [(id: String, offset: CGFloat, height: CGFloat)] {
        pruneDeadRows()
        guard let scrollView else { return [] }
        let top = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        let bottom = scrollView.contentOffset.y + scrollView.bounds.height - scrollView.adjustedContentInset.bottom
        return rows.compactMap { id, row in
            guard let view = row.view, view.groupId == id, view.window != nil else { return nil }
            let rect = view.convert(view.bounds, to: scrollView)
            guard rect.maxY > top, rect.minY < bottom else { return nil }
            return (id, rect.minY - top, rect.height)
        }
    }

    private func visibleRow() -> (id: String, offset: CGFloat)? {
        visibleRows().min { $0.offset < $1.offset }.map { ($0.id, $0.offset) }
    }

    /// The row nearest the middle of the viewport. A lazy container keeps the
    /// rows around its viewport, so this one best survives an estimated move.
    private func middleRow() -> (id: String, offset: CGFloat)? {
        guard let scrollView else { return nil }
        let middle = (scrollView.bounds.height - scrollView.adjustedContentInset.top
            - scrollView.adjustedContentInset.bottom) / 2
        return visibleRows().min {
            abs($0.offset + $0.height / 2 - middle) < abs($1.offset + $1.height / 2 - middle)
        }.map { ($0.id, $0.offset) }
    }

    func prepare(for snapshot: ChatListWindowSnapshotFfi) {
        prepare(anchor: snapshot.anchor, sequence: snapshot.sequence)
    }

    func cancelRestoration() { pending = nil }

    /// `lazyRowIDs` is the outgoing window's rows, in order, when the container
    /// lays out only the rows around its viewport.
    func prepare(for snapshot: ConversationWindowSnapshotFfi, displayID: (String) -> String = { "msg:" + $0 },
                 lazyRowIDs: [String]? = nil) {
        guard let index = snapshot.anchor.index, snapshot.messages.indices.contains(Int(index)) else { return }
        let id = displayID(snapshot.messages[Int(index)].timeline.messageIdHex)
        pruneDeadRows()
        // Initial positioning belongs to the conversation scroll coordinator.
        guard !rows.isEmpty else { return }
        let order = lazyRowIDs.map { _ in
            Dictionary(snapshot.messages.enumerated().map { (displayID($1.timeline.messageIdHex), $0) },
                       uniquingKeysWith: { first, _ in first })
        }
        let anchor: ChatListAnchorOutcomeFfi
        switch snapshot.anchor.kind {
        case .recoveredNext, .recoveredPrevious: anchor = .recovered(groupIdHex: id, index: index)
        default:
            let visible = lazyRowIDs == nil ? visibleRow() : middleRow()
            if let visible, snapshot.messages.contains(where: { displayID($0.timeline.messageIdHex) == visible.id }) {
                anchor = .retained(groupIdHex: visible.id, index: index)
            } else {
                anchor = .recovered(groupIdHex: id, index: index)
            }
        }
        prepare(anchor: anchor, sequence: snapshot.revision.sequence)
        guard let order, let lazyRowIDs, var pending, let scrollView, let rowID = pending.groupId else { return }
        var estimatedMove: CGFloat = 0
        if let newIndex = order[rowID], let oldIndex = lazyRowIDs.firstIndex(of: rowID) {
            estimatedMove = Self.estimatedHeight(ofRows: newIndex - oldIndex,
                                                 contentHeight: scrollView.contentSize.height, rowCount: lazyRowIDs.count)
        }
        pending.lazy = LazyRestoration(order: order, startOffset: scrollView.contentOffset.y,
                                       placedOffset: scrollView.contentOffset.y, estimatedMove: estimatedMove)
        self.pending = pending
    }

    /// A lazy container lays out only the rows around its viewport, so rows
    /// landing above the reader's row would push it out of layout before it
    /// could be restored. Moving the viewport by their estimated height keeps
    /// the row laid out; `restoreIfReady` then corrects the estimate. Call once
    /// the replacement's rows are in the model and before they render, so the
    /// container lays out the new rows at the new offset in one pass.
    func followPendingRow() {
        guard var pending, var lazy = pending.lazy, lazy.estimatedMove != 0, let scrollView else { return }
        let offset = lazy.place(at: lazy.startOffset + lazy.estimatedMove, from: scrollView.contentOffset.y)
        lazy.estimatedMove = 0
        pending.lazy = lazy
        self.pending = pending
        scrollView.contentOffset.y = offset
    }

    /// Height of `rows` rows in a container that averages `contentHeight` over
    /// `rowCount` rows; negative when rows were removed.
    nonisolated static func estimatedHeight(ofRows rows: Int, contentHeight: CGFloat, rowCount: Int) -> CGFloat {
        guard rowCount > 0, contentHeight > 0 else { return 0 }
        return CGFloat(rows) * contentHeight / CGFloat(rowCount)
    }

    /// Rows register one at a time during a layout pass, so whether the pending
    /// row was dropped is only known once the pass has finished.
    private func searchForPendingRowIfDropped(seenFrom view: ChatListAnchorView) {
        guard var pending, var lazy = pending.lazy, !lazy.isSearchScheduled,
              pending.sequence == view.sequence, let id = pending.groupId, id != view.groupId else { return }
        lazy.isSearchScheduled = true
        pending.lazy = lazy
        self.pending = pending
        let sequence = pending.sequence
        Task { @MainActor [weak self] in self?.moveTowardPendingRow(sequence: sequence) }
    }

    /// Moves the viewport to where the pending row should be, judged from the
    /// nearest row that is laid out, so the container lays it out too.
    private func moveTowardPendingRow(sequence: UInt64) {
        guard var pending, var lazy = pending.lazy, pending.sequence == sequence,
              let id = pending.groupId, let scrollView else { return }
        lazy.isSearchScheduled = false
        pending.lazy = lazy
        self.pending = pending
        if let row = rows[id]?.view, row.groupId == id, row.window != nil, row.sequence == sequence {
            restoreIfReady(from: row)
            return
        }
        guard lazy.searches < Self.maximumRowSearches, let target = lazy.order[id] else {
            self.pending = nil
            return
        }
        let laidOut = rows.compactMap { rowID, row -> (index: Int, minY: CGFloat)? in
            guard let view = row.view, view.groupId == rowID, view.window != nil, view.sequence == sequence,
                  let index = lazy.order[rowID] else { return nil }
            return (index, view.convert(view.bounds, to: scrollView).minY)
        }
        guard let nearest = laidOut.min(by: { abs($0.index - target) < abs($1.index - target) }) else {
            self.pending = nil
            return
        }
        let estimatedMinY = nearest.minY + Self.estimatedHeight(
            ofRows: target - nearest.index, contentHeight: scrollView.contentSize.height, rowCount: lazy.order.count)
        lazy.searches += 1
        let offset = lazy.place(at: estimatedMinY - scrollView.adjustedContentInset.top - pending.offset,
                                from: scrollView.contentOffset.y)
        pending.lazy = lazy
        self.pending = pending
        scrollView.contentOffset.y = offset
    }

    private func prepare(anchor: ChatListAnchorOutcomeFfi, sequence: UInt64) {
        guard programmaticScroll == nil, let scrollView else {
            pending = nil
            return
        }
        pruneDeadRows()
        let retainedRow: ChatListAnchorView? = if case .retained(let id, _) = anchor,
                                                  let view = rows[id]?.view, view.groupId == id { view } else { nil }
        guard retainedRow != nil || !Self.isUserScrolling(scrollView) else {
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
            let minY = retainedRow.map { $0.convert($0.bounds, to: scrollView).minY }
            pending = Pending(groupId: id, offset: minY.map { $0 - top } ?? visible?.offset ?? 0,
                              sequence: sequence, retainedMinY: minY)
        }
    }

    func reset() {
        pending = nil
        programmaticScroll = nil
        topRequested = false
        rows = [:]
        pruneThreshold = Self.initialPruneThreshold
        scrollView = nil
    }

    private func restoreIfReady(from view: ChatListAnchorView) {
        guard !isRestoring, let pending, pending.sequence == view.sequence,
              pending.groupId == nil || pending.groupId == view.groupId,
              let scrollView, view.window != nil else { return }
        isRestoring = true
        defer { isRestoring = false }
        if Self.isUserScrolling(scrollView) {
            if let previousMinY = pending.retainedMinY {
                let delta = view.convert(view.bounds, to: scrollView).minY - previousMinY
                if var lazy = pending.lazy {
                    // The viewport has already been moved toward the row; keep only the reader's own travel.
                    scrollView.contentOffset.y = lazy.place(at: lazy.startOffset + delta, from: scrollView.contentOffset.y)
                } else {
                    scrollView.contentOffset.y += delta
                }
            }
            self.pending = nil
            return
        }
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

    private static func isUserScrolling(_ scrollView: UIScrollView) -> Bool {
        scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating
    }
}

final class ChatListAnchorView: UIView {
    var groupId = ""
    var sequence: UInt64 = 0
    weak var viewport: ChatListViewport?

    @discardableResult
    func updateAnchor(groupId: String, sequence: UInt64, viewport: ChatListViewport) -> Bool {
        guard self.groupId != groupId || self.sequence != sequence || self.viewport !== viewport else {
            return false
        }
        if !self.groupId.isEmpty, self.groupId != groupId || self.viewport !== viewport {
            self.viewport?.unregister(self, groupId: self.groupId)
        }
        self.groupId = groupId
        self.sequence = sequence
        self.viewport = viewport
        setNeedsLayout()
        return true
    }

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
        view.updateAnchor(groupId: groupId, sequence: sequence, viewport: viewport)
    }
}
