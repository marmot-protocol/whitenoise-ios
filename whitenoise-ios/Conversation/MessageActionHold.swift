import SwiftUI
import UIKit

enum MessageActionSurface { case bubble, failureNotice }

extension EnvironmentValues {
    @Entry var pressedMessageActionSurface: MessageActionSurface?
}

private struct MessageActionPressKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = nextValue() || value }
}

/// Keep the pressed surface’s shadow above neighboring rows.
struct MessageActionRowStacking: ViewModifier {
    @State private var pressing = false
    func body(content: Content) -> some View {
        content
            .onPreferenceChange(MessageActionPressKey.self) { pressing = $0 }
            .zIndex(pressing ? 1 : 0)
    }
}

struct MessageActionHold: ViewModifier {
    var surface: MessageActionSurface = .bubble
    @Environment(\.pressedMessageActionSurface) private var pressedPreview
    let isEnabled: Bool
    let open: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private enum Feedback: Equatable { case idle, pressing, releasing(UUID) }
    @State private var feedback: Feedback = .idle

    func body(content: Content) -> some View {
        let highlightsPress = (feedback == .pressing || pressedPreview == surface) && !reduceMotion
        content
            .shadow(color: .black.opacity(highlightsPress ? 0.16 : 0), radius: 10, y: 3)
            .preference(key: MessageActionPressKey.self, value: feedback != .idle && !reduceMotion)
            .gesture(MessageHoldGesture(isEnabled: isEnabled, feedback: setPressFeedback, open: open))
            .onDisappear { feedback = .idle }
    }

    private func setPressFeedback(_ pressing: Bool) {
        if pressing {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.36)) { feedback = .pressing }
        } else if feedback == .pressing {
            let release = Feedback.releasing(UUID())
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16), completionCriteria: .removed) {
                feedback = release
            } completion: {
                if feedback == release { feedback = .idle }
            }
        }
    }
}

private struct MessageHoldGesture: UIGestureRecognizerRepresentable {
    let isEnabled: Bool
    let feedback: (Bool) -> Void
    let open: () -> Void

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            other is UIPanGestureRecognizer
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
            other is MessageLinkCopyHold.Recognizer
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            guard other is UITapGestureRecognizer, let view = gestureRecognizer.view,
                  let otherView = other.view else { return false }
            return otherView === view || otherView.isDescendant(of: view)
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> MessageHoldRecognizer {
        let recognizer = MessageHoldRecognizer()
        recognizer.allowableMovement = 10
        recognizer.delegate = context.coordinator
        recognizer.isEnabled = isEnabled
        recognizer.feedback = feedback
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: MessageHoldRecognizer, context: Context) {
        recognizer.feedback = feedback
        if recognizer.isEnabled != isEnabled { recognizer.isEnabled = isEnabled }
    }

    func handleUIGestureRecognizerAction(_ recognizer: MessageHoldRecognizer, context: Context) {
        if recognizer.state == .began {
            open()
        }
    }
}

/// Visual feedback starts before recognition. UIKit remains free to deliver a tap
/// to the original control, or hand a drag to the timeline, until the full hold.
private final class MessageHoldRecognizer: UILongPressGestureRecognizer {
    var feedback: ((Bool) -> Void)?
    private var feedbackTask: Task<Void, Never>?
    private var isShowingFeedback = false
    private var origin: CGPoint?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard numberOfTouches == 1, let touch = touches.first else { endFeedback(); return }
        origin = touch.location(in: view?.window)
        feedbackTask = Task { @MainActor [weak self, weak touch] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard let self, let touch, isEnabled, state == .possible else { return }
            // A hold on a link belongs to Copy Link; keep its surrounding row still.
            if touch.gestureRecognizers?.contains(where: { $0 is MessageLinkCopyHold.Recognizer && $0.state == .possible }) == true { return }
            isShowingFeedback = true
            feedback?(true)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        if let origin, let point = touches.first?.location(in: view?.window),
           hypot(point.x - origin.x, point.y - origin.y) > allowableMovement {
            endFeedback()
            if state == .possible { state = .failed }
        }
    }

    override func reset() {
        super.reset()
        endFeedback()
    }

    func endFeedback() {
        feedbackTask?.cancel()
        feedbackTask = nil
        origin = nil
        if isShowingFeedback {
            isShowingFeedback = false
            feedback?(false)
        }
    }
}
