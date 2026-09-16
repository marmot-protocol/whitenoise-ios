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
        await settle(host.view)
        let scroll = try #require(descendants(host.view).compactMap { $0 as? UIScrollView }.first)
        scroll.setContentOffset(CGPoint(x: 0, y: 6_013), animated: false)
        await settle(host.view)
        let anchor = try #require(model.viewport.visibleAnchor())
        let oldOffset = try offset(anchor, in: host.view, scroll: scroll)
        model.viewport.prepare(for: snapshot(sequence: 1, anchor: .retained(groupIdHex: anchor, index: 0)))
        model.ids = Array(50..<250)
        model.sequence = 1
        await settle(host.view)
        let newOffset = try offset(anchor, in: host.view, scroll: scroll)
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
        await settle(host.view)
        let scroll = try #require(descendants(host.view).compactMap { $0 as? UIScrollView }.first)
        scroll.setContentOffset(CGPoint(x: 0, y: 3_013), animated: false)
        await settle(host.view)
        let anchor = try #require(model.viewport.visibleAnchor())
        let oldOffset = try offset(anchor, in: host.view, scroll: scroll)
        let oldID = try #require(Int(anchor))
        let recovered = String(oldID + 1)
        model.viewport.prepare(for: snapshot(sequence: 1, anchor: .recovered(groupIdHex: recovered, index: 0)))
        model.ids.removeAll { $0 == oldID }
        model.sequence = 1
        await settle(host.view)
        let newOffset = try offset(recovered, in: host.view, scroll: scroll)
        #expect(abs(newOffset - oldOffset) < 2)
    }

    private func snapshot(sequence: UInt64, anchor: ChatListAnchorOutcomeFfi) -> ChatListWindowSnapshotFfi {
        ChatListWindowSnapshotFfi(subscriptionGeneration: "test", sequence: sequence, view: .chats,
                                  rows: [], hasMoreBefore: true, hasMoreAfter: true, anchor: anchor)
    }

    private func offset(_ id: String, in view: UIView, scroll: UIScrollView) throws -> CGFloat {
        let row = try #require(descendants(view).compactMap { $0 as? ChatListAnchorView }.first { $0.groupId == id })
        return row.convert(row.bounds, to: scroll).minY - scroll.contentOffset.y - scroll.adjustedContentInset.top
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func settle(_ view: UIView) async {
        for _ in 0..<20 {
            view.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
