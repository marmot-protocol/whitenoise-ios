import SwiftUI
import UIKit

enum ReplySwipe {
    static let activationThreshold: CGFloat = 55
    static let leadingEdgeNavigationWidth: CGFloat = 44

    private static let horizontalDominance: CGFloat = 1.2

    static func shouldBegin(velocity: CGPoint, rightToLeft: Bool = false) -> Bool {
        let forward = rightToLeft ? -velocity.x : velocity.x
        return forward > 0 && forward > abs(velocity.y) * horizontalDominance
    }

    static func shouldActivate(translation: CGSize) -> Bool {
        translation.width >= activationThreshold
            && isRightwardHorizontal(translation)
    }

    static func feedbackOffset(translation: CGSize) -> CGFloat {
        guard isRightwardHorizontal(translation) else { return 0 }
        let distance = translation.width
        if distance <= activationThreshold { return distance }
        return activationThreshold + (distance - activationThreshold) / 6
    }

    static func isInLeadingEdgeNavigationRegion(startLocation: CGPoint, in bounds: CGRect, rightToLeft: Bool = false) -> Bool {
        guard bounds.width > 0 else { return false }
        let distance = rightToLeft ? bounds.maxX - startLocation.x : startLocation.x - bounds.minX
        return distance < leadingEdgeNavigationWidth
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

extension EnvironmentValues {
    @Entry var replyGestureOffset: CGFloat = 0
}

struct ReplySwipeContentOffset: ViewModifier {
    @Environment(\.replyGestureOffset) private var offset

    func body(content: Content) -> some View {
        content.offset(x: offset)
    }
}

struct BubbleReplyIndicator: View {
    @Environment(\.replyGestureOffset) private var offset
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if offset > 0 {
            Image(systemName: "arrowshape.turn.up.left")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .scaleEffect(!reduceMotion && offset >= ReplySwipe.activationThreshold ? 1.16 : 1)
                .animation(reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.7),
                           value: offset >= ReplySwipe.activationThreshold)
                // The parent already travels with the finger.
                .offset(x: 8 + offset / 8 - offset)
                // Remove the glyph before the reply composer moves the transcript.
                .transition(.identity)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
    }
}

private struct ReplySwipeModifier: ViewModifier {
    let isEnabled: Bool
    let isNavigating: Bool
    let onReply: () -> Void

    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offset: CGFloat = 0

    private var rightToLeft: Bool { layoutDirection == .rightToLeft }
    private var ready: Bool { offset >= ReplySwipe.activationThreshold }

    func body(content: Content) -> some View {
        content
        .environment(\.replyGestureOffset, offset)
        .contentShape(.rect)
        .gesture(
            ReplySwipePanGesture(
                isEnabled: isEnabled,
                isNavigating: isNavigating,
                rightToLeft: rightToLeft,
                onChanged: handleSwipeChange,
                onEnded: handleSwipeEnd,
                onCancelled: resetReplySwipe
            )
        )
        .onChange(of: isEnabled) { _, enabled in if !enabled { resetReplySwipe() } }
        .onChange(of: isNavigating) { _, navigating in if navigating { resetReplySwipe() } }
        .onChange(of: layoutDirection) { resetReplySwipe() }
        .onDisappear { offset = 0 }
    }

    private func handleSwipeChange(_ translation: CGSize) {
        guard isEnabled, !isNavigating else { return }
        let next = ReplySwipe.feedbackOffset(translation: translation)
        if !ready, next >= ReplySwipe.activationThreshold { Haptics.tap() }
        offset = next
    }

    private func handleSwipeEnd(_ translation: CGSize) {
        let shouldReply = isEnabled && !isNavigating && ReplySwipe.shouldActivate(translation: translation)
        // UIKit can deliver the threshold crossing in the final sample.
        if shouldReply && !ready { Haptics.tap() }
        resetReplySwipe()
        if shouldReply { onReply() }
    }

    private func resetReplySwipe() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { offset = 0 }
    }
}

private struct ReplySwipePanGesture: UIGestureRecognizerRepresentable {
    let isEnabled: Bool
    let isNavigating: Bool
    let rightToLeft: Bool
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
            arbiter.rightToLeft = gesture.rightToLeft
        }
    }

    func makeCoordinator(converter _: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(gesture: self)
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let gesture = UIPanGestureRecognizer()
        gesture.isEnabled = isEnabled
        gesture.cancelsTouchesInView = false
        gesture.maximumNumberOfTouches = 1
        gesture.delegate = context.coordinator.arbiter
        return gesture
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.gesture = self
        context.coordinator.arbiter.isNavigating = isNavigating
        context.coordinator.arbiter.rightToLeft = rightToLeft
        if recognizer.isEnabled != isEnabled {
            recognizer.isEnabled = isEnabled
        }
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view)
        let size = CGSize(width: rightToLeft ? -translation.x : translation.x, height: translation.y)
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
