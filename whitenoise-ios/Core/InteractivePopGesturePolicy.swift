/// Decides whether the screen-edge back swipe may start once the app has taken
/// over `interactivePopGestureRecognizer`'s delegate. Bypassing UIKit's own
/// delegate means restating its guards: popping the root controller, or
/// starting a second pop while one is still animating, wedges the stack.
enum InteractivePopGesturePolicy {
    static func shouldBegin(stackDepth: Int, isTransitioning: Bool) -> Bool {
        stackDepth > 1 && !isTransitioning
    }
}
