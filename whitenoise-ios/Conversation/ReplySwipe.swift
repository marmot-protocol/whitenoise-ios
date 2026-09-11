import SwiftUI
import UIKit

enum ReplySwipe {
    static let minimumDistance: CGFloat = 24
    static let activationThreshold: CGFloat = 60
    static let maximumFeedbackOffset: CGFloat = 32
    static let completionOffset: CGFloat = 12
    static let completionAnimationDuration: TimeInterval = 0.045
    static let resetAnimationDuration: TimeInterval = 0.08
    static let completionPauseNanoseconds: UInt64 = 18_000_000
    /// UIKit's screen-edge pop recognizer claims roughly this much of the
    /// leading edge. A rightward drag that starts inside it is the back
    /// swipe, so the reply gesture must not compete for it.
    static let leadingEdgeNavigationWidth: CGFloat = 44

    private static let horizontalDominance: CGFloat = 1.2

    static func shouldBegin(velocity: CGPoint) -> Bool {
        velocity.x > 0
            && velocity.x > abs(velocity.y) * horizontalDominance
    }

    static func shouldActivate(translation: CGSize) -> Bool {
        translation.width > activationThreshold
            && isRightwardHorizontal(translation)
    }

    static func feedbackOffset(translation: CGSize) -> CGFloat {
        guard translation.width >= minimumDistance,
              isRightwardHorizontal(translation)
        else { return 0 }
        return min(maximumFeedbackOffset, translation.width * 0.42)
    }

    static func isInLeadingEdgeNavigationRegion(startLocation: CGPoint, in bounds: CGRect) -> Bool {
        guard bounds.width > 0 else { return false }
        return startLocation.x - bounds.minX < leadingEdgeNavigationWidth
    }

    private static func isRightwardHorizontal(_ translation: CGSize) -> Bool {
        translation.width > 0
            && translation.width > abs(translation.height) * horizontalDominance
    }
}

extension View {
    func replySwipeToReply(
        isEnabled: Bool,
        isNavigating: Bool,
        onReply: @escaping () -> Void
    ) -> some View {
        modifier(
            ReplySwipeModifier(
                isEnabled: isEnabled,
                isNavigating: isNavigating,
                onReply: onReply
            )
        )
    }
}

private struct ReplySwipeModifier: ViewModifier {
    let isEnabled: Bool
    let isNavigating: Bool
    let onReply: () -> Void

    @State private var offset: CGFloat = 0
    @State private var resetTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        if isEnabled {
            ZStack(alignment: .leading) {
                if offset > 0 {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: ReplySwipe.maximumFeedbackOffset)
                        .opacity(min(1, offset / ReplySwipe.maximumFeedbackOffset))
                        .scaleEffect(offset >= ReplySwipe.maximumFeedbackOffset ? 1 : 0.82)
                        .accessibilityHidden(true)
                }

                content
                    .offset(x: offset)
            }
                .contentShape(.rect)
                .gesture(
                    ReplySwipePanGesture(
                        isNavigating: isNavigating,
                        onChanged: handleSwipeChange,
                        onEnded: handleSwipeEnd,
                        onCancelled: resetReplySwipe
                    )
                )
                .onDisappear { resetTask?.cancel() }
                .onChange(of: isNavigating) { _, navigating in
                    // The pop owns the touch now; a queued reply must not land
                    // behind the transition.
                    if navigating { resetReplySwipe() }
                }
        } else {
            content
        }
    }

    private func handleSwipeChange(_ translation: CGSize) {
        let nextOffset = ReplySwipe.feedbackOffset(translation: translation)
        guard nextOffset > 0 || offset > 0 else { return }
        resetTask?.cancel()
        offset = nextOffset
    }

    private func handleSwipeEnd(_ translation: CGSize) {
        if ReplySwipe.shouldActivate(translation: translation) {
            completeReplySwipe()
        } else {
            resetReplySwipe()
        }
    }

    private func completeReplySwipe() {
        guard !isNavigating else {
            resetReplySwipe()
            return
        }
        resetTask?.cancel()
        Haptics.tap()
        withAnimation(.snappy(duration: ReplySwipe.completionAnimationDuration, extraBounce: 0)) {
            offset = ReplySwipe.completionOffset
        }
        resetTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: ReplySwipe.completionPauseNanoseconds)
            } catch {
                return
            }
            withAnimation(.snappy(duration: ReplySwipe.resetAnimationDuration, extraBounce: 0)) {
                offset = 0
            }
            resetTask = nil
            guard !isNavigating else { return }
            onReply()
        }
    }

    private func resetReplySwipe() {
        resetTask?.cancel()
        withAnimation(.snappy(duration: ReplySwipe.resetAnimationDuration, extraBounce: 0)) {
            offset = 0
        }
        resetTask = nil
    }
}

private struct ReplySwipePanGesture: UIGestureRecognizerRepresentable {
    let isNavigating: Bool
    let onChanged: (CGSize) -> Void
    let onEnded: (CGSize) -> Void
    let onCancelled: () -> Void

    @MainActor
    final class Coordinator: NSObject {
        let arbiter = ReplySwipeGestureArbiter()
        var gesture: ReplySwipePanGesture

        init(gesture: ReplySwipePanGesture) {
            self.gesture = gesture
            arbiter.isNavigating = gesture.isNavigating
        }
    }

    func makeCoordinator(converter _: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(gesture: self)
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let gesture = UIPanGestureRecognizer()
        gesture.cancelsTouchesInView = false
        gesture.maximumNumberOfTouches = 1
        gesture.delegate = context.coordinator.arbiter
        return gesture
    }

    func updateUIGestureRecognizer(_: UIPanGestureRecognizer, context: Context) {
        context.coordinator.gesture = self
        context.coordinator.arbiter.isNavigating = isNavigating
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view)
        let size = CGSize(width: translation.x, height: translation.y)
        switch recognizer.state {
        case .began, .changed:
            context.coordinator.gesture.onChanged(size)
        case .ended:
            context.coordinator.gesture.onEnded(size)
        case .cancelled, .failed:
            context.coordinator.gesture.onCancelled()
        case .possible:
            break
        @unknown default:
            context.coordinator.gesture.onCancelled()
        }
    }
}
