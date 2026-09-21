import MarmotKit
import Testing
import UIKit
@testable import whitenoise_ios

@MainActor
@Suite
struct ChatListViewportTests {
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
        sequence: UInt64 = 0
    ) throws -> (window: UIWindow, scroll: UIScrollView) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: viewportHeight)
        let scroll = UIScrollView(frame: window.bounds)
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
}
