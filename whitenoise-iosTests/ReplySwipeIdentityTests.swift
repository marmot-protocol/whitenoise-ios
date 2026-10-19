import SwiftUI
import Testing
import UIKit
@testable import whitenoise_ios

@MainActor
@Suite(.serialized)
struct ReplySwipeIdentityTests {
    @Test func changingReplyAvailabilityPreservesTheDisplayedBubble() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let probe = Probe()
        let host = UIHostingController(rootView: row(enabled: false, probe: probe))
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        let original = try #require(probe.view)

        // A cached conversation becomes replyable when its live capabilities arrive.
        host.rootView = row(enabled: true, probe: probe)
        window.setNeedsLayout()
        window.layoutIfNeeded()
        await Task.yield()
        window.layoutIfNeeded()
        #expect(probe.view === original)

        // Losing reply permission must not discard the already rendered content either.
        host.rootView = row(enabled: false, probe: probe)
        window.setNeedsLayout()
        window.layoutIfNeeded()
        await Task.yield()
        window.layoutIfNeeded()
        #expect(probe.view === original)
    }

    private func row(enabled: Bool, probe: Probe) -> some View {
        BubbleProbe(probe: probe)
            .frame(width: 100, height: 44)
            .replySwipeToReply(isEnabled: enabled, isNavigating: false, onReply: {})
    }

    private final class Probe {
        var view: UIView?
    }

    private struct BubbleProbe: UIViewRepresentable {
        let probe: Probe

        func makeUIView(context: Context) -> UIView {
            let view = UIView()
            probe.view = view
            return view
        }

        func updateUIView(_ uiView: UIView, context: Context) {}
    }
}
