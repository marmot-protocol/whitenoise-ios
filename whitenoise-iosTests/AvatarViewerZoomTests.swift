import SwiftUI
import Testing
import UIKit
@testable import whitenoise_ios

@MainActor
struct AvatarViewerZoomTests {
    @Test func hostedAvatarViewerZoomsLikeTheMediaViewer() async throws {
        let host = UIHostingController(rootView: WNAvatarViewer { size in
            NativeAvatarBubble(seed: "Marmota", title: "Marmota", asset: nil)
                .frame(width: size, height: size)
        }.environment(AppState.test()))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousKeyWindow?.makeKey() }

        var zoom: WNZoomScrollView?
        for _ in 0..<100 where zoom?.zoomedView.frame.width ?? 0 == 0 {
            host.view.layoutIfNeeded()
            zoom = findZoomView(host.view)
            await Task.yield()
        }
        let view = try #require(zoom)
        view.layoutIfNeeded()

        #expect(abs(view.zoomedView.frame.width - view.bounds.width) < 0.5)
        #expect(abs(view.zoomedView.center.y - view.bounds.midY) < 0.5)
        #expect(view.accessibilityLabel == L10n.string("Photo"))
        #expect(!view.gestureRecognizerShouldBegin(view.panGestureRecognizer))

        view.toggleZoom(at: CGPoint(x: view.bounds.midX, y: view.bounds.midX), animated: false)
        #expect(abs(view.zoomScale - 2.5) < 0.01)
        #expect(view.gestureRecognizerShouldBegin(view.panGestureRecognizer))

        for _ in 0..<10 { view.accessibilityIncrement() }
        #expect(view.zoomScale == 5)

        view.toggleZoom(at: .zero, animated: false)
        #expect(view.zoomScale == 1)
        #expect(!view.gestureRecognizerShouldBegin(view.panGestureRecognizer))
    }

    private func findZoomView(_ view: UIView) -> WNZoomScrollView? {
        if let zoom = view as? WNZoomScrollView { return zoom }
        return view.subviews.lazy.compactMap { self.findZoomView($0) }.first
    }
}
