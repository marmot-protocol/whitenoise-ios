import SwiftUI

enum ReplySwipe {
    static let minimumDistance: CGFloat = 24
    static let activationThreshold: CGFloat = 60
    static let maximumFeedbackOffset: CGFloat = 32
    static let completionOffset: CGFloat = 12
    static let completionAnimationDuration: TimeInterval = 0.045
    static let resetAnimationDuration: TimeInterval = 0.08
    static let completionPauseNanoseconds: UInt64 = 18_000_000

    private static let horizontalDominance: CGFloat = 1.2

    static func shouldActivate(translation: CGSize) -> Bool {
        translation.width > activationThreshold
            && isRightwardHorizontal(translation)
    }

    static func feedbackOffset(translation: CGSize) -> CGFloat {
        guard isRightwardHorizontal(translation) else { return 0 }
        return min(maximumFeedbackOffset, translation.width * 0.42)
    }

    private static func isRightwardHorizontal(_ translation: CGSize) -> Bool {
        translation.width > 0
            && translation.width > abs(translation.height) * horizontalDominance
    }
}

extension View {
    func replySwipeToReply(isEnabled: Bool, onReply: @escaping () -> Void) -> some View {
        modifier(ReplySwipeModifier(isEnabled: isEnabled, onReply: onReply))
    }
}

private struct ReplySwipeModifier: ViewModifier {
    let isEnabled: Bool
    let onReply: () -> Void

    @State private var offset: CGFloat = 0
    @State private var resetTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .offset(x: offset)
                .simultaneousGesture(swipeGesture)
                .onDisappear { resetTask?.cancel() }
        } else {
            content
        }
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: ReplySwipe.minimumDistance, coordinateSpace: .local)
            .onChanged { value in
                let nextOffset = ReplySwipe.feedbackOffset(translation: value.translation)
                guard nextOffset > 0 || offset > 0 else { return }
                resetTask?.cancel()
                offset = nextOffset
            }
            .onEnded { value in
                if ReplySwipe.shouldActivate(translation: value.translation) {
                    completeReplySwipe()
                } else {
                    resetReplySwipe()
                }
            }
    }

    private func completeReplySwipe() {
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
            onReply()
            resetTask = nil
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
