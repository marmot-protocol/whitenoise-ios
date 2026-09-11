import UIKit

/// Delegate for a timeline row's reply pan. A conversation hides the
/// navigation bar and adopts the screen-edge pop recognizer itself, so the
/// reply swipe has to hand the leading edge back to navigation: it refuses to
/// start there, refuses once a pop owns the touch, and fails outright if the
/// pop recognizer starts alongside it.
@MainActor
final class ReplySwipeGestureArbiter: NSObject, UIGestureRecognizerDelegate {
    /// Mirrors `InteractivePopTransitionState.isNavigating`, so a pop that has
    /// begun or completed keeps row gestures out.
    var isNavigating = false

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
        guard !isNavigating else { return false }
        if let pop = Self.navigationPopRecognizer(for: pan), Self.ownsTouch(pop) {
            return false
        }
        guard let reference = Self.referenceView(for: pan) else { return false }
        guard !ReplySwipe.isInLeadingEdgeNavigationRegion(
            startLocation: Self.startLocation(of: pan, in: reference),
            in: reference.bounds
        ) else { return false }
        return ReplySwipe.shouldBegin(velocity: pan.velocity(in: pan.view))
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        other !== Self.navigationPopRecognizer(for: gestureRecognizer)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy other: UIGestureRecognizer
    ) -> Bool {
        other === Self.navigationPopRecognizer(for: gestureRecognizer)
    }

    /// The leading-edge region is a screen measurement, so it is read in
    /// window space and only falls back to the row when there is no window.
    static func referenceView(for recognizer: UIGestureRecognizer) -> UIView? {
        recognizer.view?.window ?? recognizer.view
    }

    /// `shouldBegin` runs a few points into the drag, so the touch-down point
    /// is recovered by backing the translation out of the current location.
    static func startLocation(of pan: UIPanGestureRecognizer, in reference: UIView) -> CGPoint {
        let location = pan.location(in: reference)
        let translation = pan.translation(in: reference)
        return CGPoint(x: location.x - translation.x, y: location.y - translation.y)
    }

    static func ownsTouch(_ recognizer: UIGestureRecognizer) -> Bool {
        switch recognizer.state {
        case .began, .changed: true
        default: false
        }
    }

    static func navigationPopRecognizer(for recognizer: UIGestureRecognizer) -> UIGestureRecognizer? {
        recognizer.view?.enclosingNavigationController()?.interactivePopGestureRecognizer
    }
}
