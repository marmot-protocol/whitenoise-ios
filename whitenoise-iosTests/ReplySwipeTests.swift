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
        #expect(!ReplySwipe.shouldActivate(translation: CGSize(width: 59, height: 4)))
        #expect(!ReplySwipe.shouldActivate(translation: CGSize(width: 90, height: 120)))
        #expect(!ReplySwipe.shouldActivate(translation: CGSize(width: 72, height: 65)))
        #expect(!ReplySwipe.shouldActivate(translation: CGSize(width: -90, height: 4)))
    }

    @Test func feedbackOffsetFollowsHorizontalDragButIsCapped() {
        let partialOffset = ReplySwipe.feedbackOffset(translation: CGSize(width: 50, height: 3))
        #expect(partialOffset > 20)
        #expect(partialOffset < ReplySwipe.maximumFeedbackOffset)
        #expect(ReplySwipe.feedbackOffset(translation: CGSize(width: 160, height: 3)) == ReplySwipe.maximumFeedbackOffset)
        #expect(ReplySwipe.feedbackOffset(translation: CGSize(width: 40, height: 80)) == 0)
        #expect(ReplySwipe.feedbackOffset(translation: CGSize(width: 20, height: 1)) == 0)
    }

    @Test func completionNudgeStaysBelowMaximumFeedback() {
        #expect(ReplySwipe.minimumDistance >= 20)
        #expect(ReplySwipe.completionOffset < ReplySwipe.maximumFeedbackOffset)
        #expect(ReplySwipe.completionOffset <= 12)
        #expect(ReplySwipe.completionPauseNanoseconds <= 20_000_000)
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
