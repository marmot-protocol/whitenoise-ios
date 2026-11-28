import MarmotKit
import SwiftUI
import Testing
import UIKit
@testable import whitenoise_ios

@MainActor
@Suite
struct ChatListViewportTests {
    enum Gesture: CaseIterable { case dragging, decelerating }

    private final class GestureScrollView: UIScrollView {
        var gesture: Gesture?
        override var isTracking: Bool { gesture == .dragging }
        override var isDragging: Bool { gesture == .dragging }
        override var isDecelerating: Bool { gesture == .decelerating }
    }

    private let rowHeight: CGFloat = 44
    private let viewportHeight: CGFloat = 700

    /// A plain scroll view stands in for the list. `ChatListViewport` only ever
    /// reads anchor frames and the enclosing scroll view, so driving those
    /// directly keeps the geometry exact instead of inheriting whatever a lazy
    /// `List` and the current device decide.
    /// `visibleRow()` ignores anchors whose `window` is nil, so the scroll view
    /// has to be hosted. The frame is pinned rather than inherited so the
    /// geometry is the same on every device and CI runner.
    private func makeList(
        ids: [String],
        viewport: ChatListViewport,
        sequence: UInt64 = 0,
        scroll: UIScrollView = UIScrollView()
    ) throws -> (window: UIWindow, scroll: UIScrollView) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: viewportHeight)
        scroll.frame = window.bounds
        scroll.contentInsetAdjustmentBehavior = .never
        let host = UIViewController()
        host.view.addSubview(scroll)
        window.rootViewController = host
        window.isHidden = false
        window.layoutIfNeeded()
        scroll.frame = CGRect(x: 0, y: 0, width: 390, height: viewportHeight)
        layout(ids: ids, in: scroll, viewport: viewport, sequence: sequence)
        return (window, scroll)
    }

    private func layout(
        ids: [String],
        in scroll: UIScrollView,
        viewport: ChatListViewport,
        sequence: UInt64
    ) {
        scroll.subviews.forEach { $0.removeFromSuperview() }
        for (index, id) in ids.enumerated() {
            let row = ChatListAnchorView()
            row.frame = CGRect(x: 0, y: CGFloat(index) * rowHeight, width: scroll.bounds.width, height: rowHeight)
            row.groupId = id
            row.sequence = sequence
            row.viewport = viewport
            scroll.addSubview(row)
        }
        scroll.contentSize = CGSize(width: scroll.bounds.width, height: CGFloat(ids.count) * rowHeight)
        scroll.layoutIfNeeded()
    }

    private func offset(of id: String, in scroll: UIScrollView) throws -> CGFloat {
        let row = try #require(
            scroll.subviews.compactMap { $0 as? ChatListAnchorView }.first { $0.groupId == id },
            "Row \(id) is not in the list"
        )
        return row.frame.minY - scroll.contentOffset.y - scroll.adjustedContentInset.top
    }

    private func snapshot(sequence: UInt64, anchor: ChatListAnchorOutcomeFfi) -> ChatListWindowSnapshotFfi {
        ChatListWindowSnapshotFfi(subscriptionGeneration: "test", sequence: sequence, view: .chats,
                                  rows: [], hasMoreBefore: true, hasMoreAfter: true, anchor: anchor)
    }

    @Test func visibleAnchorReportsTheTopmostRowInsideTheViewport() throws {
        let viewport = ChatListViewport()
        let (window, scroll) = try makeList(ids: (0..<200).map(String.init), viewport: viewport)
        defer { window.isHidden = true; window.rootViewController = nil }
        scroll.contentOffset = CGPoint(x: 0, y: 100 * rowHeight)
        scroll.layoutIfNeeded()
        #expect(viewport.visibleAnchor() == "100")
    }

    @Test func openingBelowAllMessagesReturnsToTheVisibleTailWithoutUserInput() async throws {
        let viewport = ChatListViewport()
        let (window, scroll) = try makeList(ids: [], viewport: viewport)
        defer { window.isHidden = true; window.rootViewController = nil }
        scroll.contentInset.bottom = 20
        func measurement() -> TimelineTailMeasurement {
            let inset = scroll.adjustedContentInset
            let geometry = ScrollGeometry(contentOffset: scroll.contentOffset, contentSize: scroll.contentSize,
                contentInsets: EdgeInsets(top: inset.top, leading: inset.left, bottom: inset.bottom, trailing: inset.right),
                containerSize: scroll.bounds.size)
            return TimelineTailMeasurement(lastRowID: "127", geometry: geometry, isOpening: true)
        }
        // Unused space while only the first row is measured is a legal opening position.
        scroll.contentSize.height = rowHeight
        #expect(measurement().permitsOpeningConfirmation(lastRowID: "127"))
        scroll.contentSize.height = 128 * rowHeight
        let lastRow = CGRect(x: 0, y: scroll.contentSize.height - rowHeight, width: 100, height: rowHeight)
        let end = scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height
        scroll.contentOffset.y = end + 850
        #expect(!scroll.bounds.inset(by: scroll.adjustedContentInset).intersects(lastRow))
        #expect(!measurement().permitsOpeningConfirmation(lastRowID: "127"))
        // No lazy row can attach the viewport while the screen is entirely blank.
        let attachment = TimelineKeyboardDismissAttachmentView()
        attachment.onScrollViewReady = { scroll in
            viewport.attachScrollView(scroll)
            _ = viewport.clampOpeningOverscroll()
        }
        scroll.addSubview(attachment)
        try await eventually { scroll.bounds.inset(by: scroll.adjustedContentInset).contains(lastRow) }
        #expect(abs(scroll.contentOffset.y - end) <= 1)
        #expect(measurement().permitsOpeningConfirmation(lastRowID: "127"))
        #expect(!viewport.clampOpeningOverscroll())
    }

    @Test func retainedRowKeepsPixelOffsetAfterLeadingRowsAreEvicted() throws {
        let viewport = ChatListViewport()
        let (window, scroll) = try makeList(ids: (0..<200).map(String.init), viewport: viewport)
        defer { window.isHidden = true; window.rootViewController = nil }
        scroll.contentOffset = CGPoint(x: 0, y: 100 * rowHeight + 17)
        scroll.layoutIfNeeded()

        let anchor = try #require(viewport.visibleAnchor())
        let oldOffset = try offset(of: anchor, in: scroll)

        viewport.prepare(for: snapshot(sequence: 1, anchor: .retained(groupIdHex: anchor, index: 0)))
        layout(ids: (50..<250).map(String.init), in: scroll, viewport: viewport, sequence: 1)

        let newOffset = try offset(of: anchor, in: scroll)
        #expect(abs(newOffset - oldOffset) < 0.5, "Retained row moved \(newOffset - oldOffset)pt")
    }

    @Test func forwardPagesPreserveTheReadersOffsetAtEachLoadedEdge() throws {
        let viewport = ChatListViewport()
        let (window, scroll) = try makeList(ids: (0..<100).map(String.init), viewport: viewport)
        defer { window.isHidden = true; window.rootViewController = nil }
        for page in 1...3 {
            scroll.contentOffset.y = scroll.contentSize.height - viewportHeight
            scroll.layoutIfNeeded()
            let anchor = try #require(viewport.visibleAnchor())
            let oldOffset = try offset(of: anchor, in: scroll)
            viewport.prepare(for: snapshot(sequence: UInt64(page),
                anchor: .retained(groupIdHex: anchor, index: 0)))
            // Forward paging may evict older rows as well as append newer ones.
            layout(ids: (page * 50..<(page * 50 + 100)).map(String.init),
                in: scroll, viewport: viewport, sequence: UInt64(page))
            #expect(abs(try offset(of: anchor, in: scroll) - oldOffset) < 0.5)
            #expect(scroll.contentOffset.y < scroll.contentSize.height - viewportHeight - rowHeight)
        }
    }

    @Test(arguments: Gesture.allCases)
    func retainedRowFollowsTheReaderWhenAPageLandsMidGesture(gesture: Gesture) throws {
        let viewport = ChatListViewport()
        let gestureScroll = GestureScrollView()
        let (window, scroll) = try makeList(ids: (0..<200).map(String.init), viewport: viewport, scroll: gestureScroll)
        defer { window.isHidden = true; window.rootViewController = nil }
        scroll.contentOffset = CGPoint(x: 0, y: 100 * rowHeight + 17)
        scroll.layoutIfNeeded()

        let anchor = try #require(viewport.visibleAnchor())
        let oldOffset = try offset(of: anchor, in: scroll)
        gestureScroll.gesture = gesture

        viewport.prepare(for: snapshot(sequence: 1, anchor: .retained(groupIdHex: anchor, index: 0)))
        let gestureTravel: CGFloat = 30
        scroll.contentOffset.y += gestureTravel
        layout(ids: (50..<250).map(String.init), in: scroll, viewport: viewport, sequence: 1)

        let newOffset = try offset(of: anchor, in: scroll)
        #expect(abs(newOffset - (oldOffset - gestureTravel)) < 0.5,
                "Retained row moved \(newOffset - oldOffset)pt during a \(gesture) gesture")
    }

    // MARK: - Lazy containers

    /// A lazy container lays out only the rows around its viewport, at the
    /// positions the full list would give them.
    private func layoutLazily(ids: [String], in scroll: UIScrollView, viewport: ChatListViewport, sequence: UInt64) {
        scroll.subviews.forEach { $0.removeFromSuperview() }
        scroll.contentSize = CGSize(width: scroll.bounds.width, height: CGFloat(ids.count) * rowHeight)
        let laidOut = (scroll.contentOffset.y - rowHeight)...(scroll.contentOffset.y + viewportHeight + rowHeight)
        for (index, id) in ids.enumerated() where laidOut.contains(CGFloat(index) * rowHeight) {
            let row = ChatListAnchorView()
            row.frame = CGRect(x: 0, y: CGFloat(index) * rowHeight, width: scroll.bounds.width, height: rowHeight)
            row.groupId = id
            row.sequence = sequence
            row.viewport = viewport
            scroll.addSubview(row)
        }
        scroll.layoutIfNeeded()
    }

    private func window(_ ids: [String], sequence: UInt64) -> ConversationWindowSnapshotFfi {
        var snapshot = conversationWindowSnapshot(messages: ids.map { conversationMessage(timelineRecord(messageIdHex: $0, timelineAt: 1)) })
        snapshot.revision = ConversationWindowRevisionFfi(generation: "test", sequence: sequence)
        snapshot.anchor = ConversationAnchorOutcomeFfi(kind: .retained, index: 0)
        return snapshot
    }

    /// The row a lazy restoration follows: the one nearest the middle of the viewport.
    private func middleRow(in scroll: UIScrollView) throws -> String {
        let middle = scroll.contentOffset.y + viewportHeight / 2
        return try #require(scroll.subviews.compactMap { $0 as? ChatListAnchorView }
            .min { abs($0.frame.midY - middle) < abs($1.frame.midY - middle) }?.groupId)
    }

    @Test(arguments: [Gesture?.none, .dragging, .decelerating])
    func aPageAboveTheReaderKeepsTheirRowInALazyContainer(gesture: Gesture?) throws {
        let viewport = ChatListViewport()
        let gestureScroll = GestureScrollView()
        let old = (100..<200).map(String.init)
        let (window, scroll) = try makeList(ids: [], viewport: viewport, scroll: gestureScroll)
        defer { window.isHidden = true; window.rootViewController = nil }
        scroll.contentSize.height = CGFloat(old.count) * rowHeight
        scroll.contentOffset.y = 10 * rowHeight + 17
        layoutLazily(ids: old, in: scroll, viewport: viewport, sequence: 0)
        let anchor = try middleRow(in: scroll)
        let oldOffset = try offset(of: anchor, in: scroll)
        gestureScroll.gesture = gesture

        let new = (50..<200).map(String.init)
        viewport.prepare(for: self.window(new, sequence: 1), displayID: { $0 }, lazyRowIDs: old)
        viewport.followPendingRow()
        // A gesture keeps moving the viewport while the page lands.
        let gestureTravel: CGFloat = gesture == nil ? 0 : 30
        scroll.contentOffset.y += gestureTravel
        layoutLazily(ids: new, in: scroll, viewport: viewport, sequence: 1)

        #expect(abs(try offset(of: anchor, in: scroll) - (oldOffset - gestureTravel)) < 0.5)
    }

    @Test(arguments: [Gesture?.none, .dragging, .decelerating])
    func aRowTheLazyContainerDroppedIsFoundAgain(gesture: Gesture?) async throws {
        let viewport = ChatListViewport()
        let gestureScroll = GestureScrollView()
        let old = (100..<200).map(String.init)
        let (window, scroll) = try makeList(ids: [], viewport: viewport, scroll: gestureScroll)
        defer { window.isHidden = true; window.rootViewController = nil }
        scroll.contentSize.height = CGFloat(old.count) * rowHeight
        scroll.contentOffset.y = 10 * rowHeight + 17
        layoutLazily(ids: old, in: scroll, viewport: viewport, sequence: 0)
        let anchor = try middleRow(in: scroll)
        let oldOffset = try offset(of: anchor, in: scroll)
        gestureScroll.gesture = gesture

        // The container renders the page before the viewport has moved, so the
        // reader's row is no longer among the rows it lays out.
        let new = (0..<200).map(String.init)
        viewport.prepare(for: self.window(new, sequence: 1), displayID: { $0 }, lazyRowIDs: old)
        // A gesture keeps moving the viewport while the row is being found.
        let gestureTravel: CGFloat = gesture == nil ? 0 : 30
        scroll.contentOffset.y += gestureTravel
        layoutLazily(ids: new, in: scroll, viewport: viewport, sequence: 1)
        #expect(!viewport.isLaidOut(anchor))

        try await eventually {
            layoutLazily(ids: new, in: scroll, viewport: viewport, sequence: 1)
            return viewport.isLaidOut(anchor)
        }
        #expect(abs(try offset(of: anchor, in: scroll) - (oldOffset - gestureTravel)) < 0.5)
    }

    @Test func aLazyRestorationIsAbandonedOnceANewerWindowRenders() throws {
        let viewport = ChatListViewport()
        let old = (100..<200).map(String.init)
        let (window, scroll) = try makeList(ids: [], viewport: viewport)
        defer { window.isHidden = true; window.rootViewController = nil }
        scroll.contentSize.height = CGFloat(old.count) * rowHeight
        scroll.contentOffset.y = 10 * rowHeight + 17
        layoutLazily(ids: old, in: scroll, viewport: viewport, sequence: 0)
        let anchor = try middleRow(in: scroll)

        let new = (0..<200).map(String.init)
        viewport.prepare(for: self.window(new, sequence: 1), displayID: { $0 }, lazyRowIDs: old)
        layoutLazily(ids: new, in: scroll, viewport: viewport, sequence: 2)
        // The reader scrolls on; reaching the old row must not pull them back.
        scroll.contentOffset.y = CGFloat(new.firstIndex(of: anchor)!) * rowHeight - 300
        let settled = scroll.contentOffset.y
        layoutLazily(ids: new, in: scroll, viewport: viewport, sequence: 2)

        #expect(viewport.isLaidOut(anchor))
        #expect(scroll.contentOffset.y == settled)
    }

    @Test func recoveredRowTakesTheDeletedAnchorsOffset() throws {
        let viewport = ChatListViewport()
        var ids = (0..<200).map(String.init)
        let (window, scroll) = try makeList(ids: ids, viewport: viewport)
        defer { window.isHidden = true; window.rootViewController = nil }
        scroll.contentOffset = CGPoint(x: 0, y: 100 * rowHeight + 9)
        scroll.layoutIfNeeded()

        let anchor = try #require(viewport.visibleAnchor())
        let oldOffset = try offset(of: anchor, in: scroll)
        let recovered = try #require(Int(anchor)).advanced(by: 1).description

        viewport.prepare(for: snapshot(sequence: 1, anchor: .recovered(groupIdHex: recovered, index: 0)))
        ids.removeAll { $0 == anchor }
        layout(ids: ids, in: scroll, viewport: viewport, sequence: 1)

        let newOffset = try offset(of: recovered, in: scroll)
        #expect(abs(newOffset - oldOffset) < 0.5, "Recovered row moved \(newOffset - oldOffset)pt")
    }

    @Test func requestTopOverridesTheRetainedOffset() throws {
        let viewport = ChatListViewport()
        let (window, scroll) = try makeList(ids: (0..<200).map(String.init), viewport: viewport)
        defer { window.isHidden = true; window.rootViewController = nil }
        scroll.contentOffset = CGPoint(x: 0, y: 100 * rowHeight)
        scroll.layoutIfNeeded()

        viewport.requestTop()
        #expect(scroll.contentOffset.y == -scroll.adjustedContentInset.top)
    }

    @Test func anchorUpdateSkipsLayoutInvalidationWhenIdentityAndSequenceAreUnchanged() throws {
        let viewport = ChatListViewport()
        let (window, scroll) = try makeList(ids: [], viewport: viewport)
        defer { window.isHidden = true; window.rootViewController = nil }

        let anchorView = ChatListAnchorView()
        anchorView.frame = CGRect(x: 0, y: 0, width: scroll.bounds.width, height: rowHeight)
        scroll.addSubview(anchorView)

        #expect(anchorView.updateAnchor(groupId: "row-1", sequence: 1, viewport: viewport))
        scroll.layoutIfNeeded()
        #expect(!anchorView.layer.needsLayout())

        // Repeating the same identity, sequence, and viewport must not dirty UIKit layout.
        #expect(!anchorView.updateAnchor(groupId: "row-1", sequence: 1, viewport: viewport))
        #expect(!anchorView.layer.needsLayout())

        // Changing sequence, groupId, or viewport marks layout dirty again.
        #expect(anchorView.updateAnchor(groupId: "row-1", sequence: 2, viewport: viewport))
        #expect(anchorView.layer.needsLayout())
        scroll.layoutIfNeeded()
        #expect(!anchorView.layer.needsLayout())

        #expect(anchorView.updateAnchor(groupId: "row-2", sequence: 2, viewport: viewport))
        #expect(anchorView.layer.needsLayout())
        #expect(!viewport.isLaidOut("row-1"))
        scroll.layoutIfNeeded()
        #expect(viewport.isLaidOut("row-2"))

        // After `viewport.reset()`, an unchanged anchor must re-register rather
        // than early-returning while absent from the viewport map.
        viewport.reset()
        #expect(!viewport.isLaidOut("row-2"))
        #expect(anchorView.updateAnchor(groupId: "row-2", sequence: 2, viewport: viewport))
        #expect(anchorView.layer.needsLayout())
        scroll.layoutIfNeeded()
        #expect(viewport.isLaidOut("row-2"))
    }

    @Test func lazyPruningReclaimsDeallocatedRowsAndIgnoresReassignedKeys() throws {
        let viewport = ChatListViewport()
        let (window, scroll) = try makeList(ids: [], viewport: viewport)
        defer { window.isHidden = true; window.rootViewController = nil }

        // Register many transient rows that are then detached and released.
        for index in 0..<260 {
            autoreleasepool {
                let row = ChatListAnchorView()
                row.groupId = "dead-\(index)"
                row.sequence = 1
                row.viewport = viewport
                viewport.register(row)
            }
        }

        // A live row triggers amortized pruning once capacity crosses the threshold.
        let liveRow = ChatListAnchorView()
        liveRow.frame = CGRect(x: 0, y: 0, width: scroll.bounds.width, height: rowHeight)
        scroll.addSubview(liveRow)
        liveRow.updateAnchor(groupId: "live-old", sequence: 2, viewport: viewport)
        scroll.layoutIfNeeded()

        #expect(viewport.visibleAnchor() == "live-old")
        #expect(viewport.isLaidOut("live-old"))
        #expect(!viewport.isLaidOut("dead-0"))
        #expect(!viewport.isLaidOut("dead-259"))

        // Direct groupId reassignment without unregistering must not leave stale laid-out hits.
        liveRow.groupId = "live-new"
        #expect(!viewport.isLaidOut("live-old"))
        viewport.register(liveRow)
        #expect(viewport.isLaidOut("live-new"))
    }
}
