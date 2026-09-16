import Combine
import SwiftUI
import Testing
import MarmotKit
@testable import whitenoise_ios

@MainActor
private final class WindowListFixture: ObservableObject {
    @Published var ids = Array(0..<200)
    @Published var sequence: UInt64 = 0
    let viewport = ChatListViewport()
}

private struct WindowListHarness: View {
    @ObservedObject var model: WindowListFixture
    var body: some View {
        List(model.ids, id: \.self) { id in
            Text("Chat \(id)")
                .frame(height: 44)
                .background {
                    ChatListRowAnchor(groupId: String(id), sequence: model.sequence, viewport: model.viewport)
                }
        }
        .listStyle(.plain)
    }
}

@MainActor
@Suite(.serialized, SharedWindowTestScope())
struct ChatListViewportTests {
    @Test func retainedRowKeepsPixelOffsetAfterLeadingRowsAreEvicted() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let model = WindowListFixture()
        let host = UIHostingController(rootView: WindowListHarness(model: model))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousWindow?.makeKeyAndVisible() }
        let requestedOffset: CGFloat = 6_013
        try await settle(host.view, description: "initial list layout") {
            guard let scroll = descendants(host.view).compactMap({ $0 as? UIScrollView }).first else { return false }
            return model.viewport.visibleAnchor() != nil
                && scroll.bounds.height > 0
                && scroll.contentSize.height > requestedOffset + scroll.bounds.height
        }
        let scroll = try #require(descendants(host.view).compactMap { $0 as? UIScrollView }.first)
        scroll.setContentOffset(CGPoint(x: 0, y: requestedOffset), animated: false)
        try await settle(host.view, description: "programmatic scroll") {
            model.viewport.visibleAnchor() != nil
                && abs(scroll.contentOffset.y - requestedOffset) < 1
        }
        let anchor = try #require(model.viewport.visibleAnchor())
        let oldOffset = try offset(anchor, in: host.view, scroll: scroll)
        model.viewport.prepare(for: snapshot(sequence: 1, anchor: .retained(groupIdHex: anchor, index: 0)))
        model.ids = Array(50..<250)
        model.sequence = 1
        try await settle(host.view, description: "retained row \(anchor) at offset \(oldOffset)") {
            model.viewport.visibleAnchor() == anchor
                && rowOffset(anchor, sequence: 1, in: host.view, scroll: scroll).map { abs($0 - oldOffset) < 2 } == true
        }
        let newOffset = try offset(anchor, sequence: 1, in: host.view, scroll: scroll)
        #expect(abs(newOffset - oldOffset) < 2)
        #expect(model.viewport.visibleAnchor() == anchor)
    }

    @Test func recoveredRowTakesTheDeletedAnchorsOffset() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let model = WindowListFixture()
        let host = UIHostingController(rootView: WindowListHarness(model: model))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousWindow?.makeKeyAndVisible() }
        let requestedOffset: CGFloat = 3_013
        try await settle(host.view, description: "initial list layout") {
            guard let scroll = descendants(host.view).compactMap({ $0 as? UIScrollView }).first else { return false }
            return model.viewport.visibleAnchor() != nil
                && scroll.bounds.height > 0
                && scroll.contentSize.height > requestedOffset + scroll.bounds.height
        }
        let scroll = try #require(descendants(host.view).compactMap { $0 as? UIScrollView }.first)
        scroll.setContentOffset(CGPoint(x: 0, y: requestedOffset), animated: false)
        try await settle(host.view, description: "programmatic scroll") {
            model.viewport.visibleAnchor() != nil
                && abs(scroll.contentOffset.y - requestedOffset) < 1
        }
        let anchor = try #require(model.viewport.visibleAnchor())
        let oldOffset = try offset(anchor, in: host.view, scroll: scroll)
        let oldID = try #require(Int(anchor))
        let recovered = String(oldID + 1)
        model.viewport.prepare(for: snapshot(sequence: 1, anchor: .recovered(groupIdHex: recovered, index: 0)))
        model.ids.removeAll { $0 == oldID }
        model.sequence = 1
        try await settle(host.view, description: "recovered row \(recovered) at offset \(oldOffset)") {
            rowOffset(recovered, sequence: 1, in: host.view, scroll: scroll).map { abs($0 - oldOffset) < 2 } == true
        }
        let newOffset = try offset(recovered, sequence: 1, in: host.view, scroll: scroll)
        #expect(abs(newOffset - oldOffset) < 2)
    }

    private func snapshot(sequence: UInt64, anchor: ChatListAnchorOutcomeFfi) -> ChatListWindowSnapshotFfi {
        ChatListWindowSnapshotFfi(subscriptionGeneration: "test", sequence: sequence, view: .chats,
                                  rows: [], hasMoreBefore: true, hasMoreAfter: true, anchor: anchor)
    }

    private func offset(_ id: String, sequence: UInt64 = 0, in view: UIView, scroll: UIScrollView) throws -> CGFloat {
        try #require(rowOffset(id, sequence: sequence, in: view, scroll: scroll))
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func rowOffset(_ id: String, sequence: UInt64, in view: UIView, scroll: UIScrollView) -> CGFloat? {
        guard let row = descendants(view).compactMap({ $0 as? ChatListAnchorView }).first(where: {
            $0.groupId == id && $0.sequence == sequence && $0.window != nil && $0.bounds.height > 0
        }) else { return nil }
        return row.convert(row.bounds, to: scroll).minY - scroll.contentOffset.y - scroll.adjustedContentInset.top
    }

    private func settle(
        _ view: UIView,
        description: String,
        sourceLocation: SourceLocation = #_sourceLocation,
        until isSettled: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        var consecutiveMatches = 0
        repeat {
            view.layoutIfNeeded()
            consecutiveMatches = isSettled() ? consecutiveMatches + 1 : 0
            // Require the expected geometry to survive successive layout opportunities.
            if consecutiveMatches == 3 { return }
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        try #require(consecutiveMatches == 3, "List did not settle: \(description)", sourceLocation: sourceLocation)
    }
}
