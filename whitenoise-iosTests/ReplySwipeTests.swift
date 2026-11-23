import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

@MainActor
struct ReplySwipeTests {

    @Test func recognizerBeginsOnlyForRightwardHorizontalIntent() {
        #expect(ReplySwipe.shouldBegin(velocity: CGPoint(x: 180, y: 30)))
        #expect(!ReplySwipe.shouldBegin(velocity: CGPoint(x: 30, y: 180)))
        #expect(!ReplySwipe.shouldBegin(velocity: CGPoint(x: -180, y: 20)))
    }

    @Test func horizontalDragPastThresholdActivatesReply() {
        #expect(ReplySwipe.shouldActivate(translation: CGSize(width: 72, height: 10)))
    }

    @Test func verticalOrShortDragsDoNotActivateReply() {
        #expect(!ReplySwipe.shouldActivate(translation: CGSize(width: 54, height: 4)))
        #expect(!ReplySwipe.shouldActivate(translation: CGSize(width: 90, height: 120)))
        #expect(!ReplySwipe.shouldActivate(translation: CGSize(width: 72, height: 65)))
        #expect(!ReplySwipe.shouldActivate(translation: CGSize(width: -90, height: 4)))
    }

    @Test func feedbackTracksTheFingerToThresholdThenResistsOverdrag() {
        #expect(ReplySwipe.feedbackOffset(translation: CGSize(width: 20, height: 1)) == 20)
        let threshold = ReplySwipe.activationThreshold
        #expect(ReplySwipe.shouldActivate(translation: CGSize(width: threshold, height: 0)))
        let drag = CGSize(width: threshold + 60, height: 2)
        let offset = ReplySwipe.feedbackOffset(translation: drag)
        #expect(offset > threshold)
        #expect(offset < drag.width)
        #expect(ReplySwipe.feedbackOffset(translation: CGSize(width: 40, height: 80)) == 0)
    }

    @Test func rightToLeftReplyBeginsLeftwardAwayFromTheRightNavigationEdge() {
        let bounds = CGRect(x: 20, y: 0, width: 400, height: 800)
        #expect(ReplySwipe.shouldBegin(velocity: CGPoint(x: -180, y: 25), rightToLeft: true))
        #expect(!ReplySwipe.shouldBegin(velocity: CGPoint(x: 180, y: 25), rightToLeft: true))
        #expect(ReplySwipe.isInLeadingEdgeNavigationRegion(startLocation: CGPoint(x: 400, y: 40), in: bounds, rightToLeft: true))
        #expect(!ReplySwipe.isInLeadingEdgeNavigationRegion(startLocation: CGPoint(x: 200, y: 40), in: bounds, rightToLeft: true))
    }

    // MARK: - View identity

    @Test func changingReplyAvailabilityPreservesTheDisplayedBubble() async throws {
        let probe = Probe()
        let host = UIHostingController(rootView: row(enabled: false, probe: probe))
        try await withHostedWindow(host, awaitingFirstUpdate: false) { window in
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
