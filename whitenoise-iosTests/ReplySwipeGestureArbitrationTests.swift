import Testing
import UIKit
@testable import whitenoise_ios

/// Mirrors how `ConversationView` composes the pop transition state, the
/// composer's focus/dismiss requests, and the row arbiter, so the arbitration
/// can be driven against real recognizers.
@MainActor
private final class ConversationPopHarness {
    let arbiter = ReplySwipeGestureArbiter()
    var isComposerFocused = false
    private(set) var dismissRequests = 0
    private(set) var focusRequests = 0
    private(set) var replyTargets: [String] = []
    private var state = InteractivePopTransitionState()

    var isNavigating: Bool { state.isNavigating }

    func beginPop() -> Int? {
        guard let epoch = state.begin(isComposerFocused: isComposerFocused) else { return nil }
        dismissRequests += 1
        isComposerFocused = false
        syncArbiter()
        return epoch
    }

    func finishPop(epoch: Int, isCancelled: Bool) {
        switch state.finish(epoch: epoch, isCancelled: isCancelled) {
        case .ignored, .completed:
            break
        case .cancelled(let restoresComposerFocus):
            if restoresComposerFocus {
                requestComposerFocus()
            }
        }
        syncArbiter()
    }

    func beginReply(to messageIdHex: String) {
        guard !state.isNavigating else { return }
        replyTargets.append(messageIdHex)
        requestComposerFocus()
    }

    private func requestComposerFocus() {
        guard !state.isNavigating else { return }
        focusRequests += 1
        isComposerFocused = true
    }

    private func syncArbiter() {
        arbiter.isNavigating = state.isNavigating
    }
}

@MainActor
@Suite(.serialized)
struct ReplySwipeGestureArbitrationTests {
    private struct Stack {
        let window: UIWindow
        let navigation: UINavigationController
        let pop: UIGestureRecognizer
        let pan: UIPanGestureRecognizer
        let controller: InteractivePopGestureController
    }

    private func makeStack(harness: ConversationPopHarness) throws -> Stack {
        let windowScene = try #require(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
        )
        let pushed = UIViewController()
        let navigation = UINavigationController(rootViewController: UIViewController())
        navigation.pushViewController(pushed, animated: false)
        navigation.setNavigationBarHidden(true, animated: false)

        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        window.layoutIfNeeded()

        let controller = InteractivePopGestureController(
            onBegin: { harness.beginPop() },
            onFinish: { harness.finishPop(epoch: $0, isCancelled: $1) }
        )
        let attachment = InteractivePopGestureAttachmentView()
        attachment.controller = controller
        pushed.view.addSubview(attachment)

        let row = UIView(frame: CGRect(x: 0, y: 200, width: 390, height: 64))
        pushed.view.addSubview(row)
        let pan = UIPanGestureRecognizer()
        pan.delegate = harness.arbiter
        row.addGestureRecognizer(pan)

        window.layoutIfNeeded()
        attachment.resolveNavigationController()

        let pop = try #require(navigation.interactivePopGestureRecognizer)
        return Stack(
            window: window,
            navigation: navigation,
            pop: pop,
            pan: pan,
            controller: controller
        )
    }

    @Test func theRowsReplyPanResolvesAndYieldsToTheStacksPopRecognizer() throws {
        let harness = ConversationPopHarness()
        let stack = try makeStack(harness: harness)
        defer { stack.window.isHidden = true }

        #expect(ReplySwipeGestureArbiter.navigationPopRecognizer(for: stack.pan) === stack.pop)
        #expect(harness.arbiter.gestureRecognizer(stack.pan, shouldBeRequiredToFailBy: stack.pop))
        #expect(!harness.arbiter.gestureRecognizer(
            stack.pan,
            shouldRecognizeSimultaneouslyWith: stack.pop
        ))

        // An unrelated recognizer on the same row is still free to run.
        let other = UIPanGestureRecognizer()
        #expect(harness.arbiter.gestureRecognizer(
            stack.pan,
            shouldRecognizeSimultaneouslyWith: other
        ))
        #expect(!harness.arbiter.gestureRecognizer(stack.pan, shouldBeRequiredToFailBy: other))
    }

    @Test func anEdgePopBlocksTheReplyPanAndEveryDelayedReplyBehindIt() throws {
        let harness = ConversationPopHarness()
        let stack = try makeStack(harness: harness)
        defer { stack.window.isHidden = true }

        #expect(stack.controller.gestureRecognizerShouldBegin(stack.pop))
        #expect(harness.dismissRequests == 1)
        #expect(harness.isNavigating)
        #expect(harness.arbiter.isNavigating)

        // The row's pan can no longer start...
        #expect(!harness.arbiter.gestureRecognizerShouldBegin(stack.pan))
        // ...and a reply the row already scheduled cannot land.
        harness.beginReply(to: "0011")
        #expect(harness.replyTargets.isEmpty)
        #expect(harness.focusRequests == 0)

        stack.controller.completeTransition(isCancelled: false)

        // Still refused after the transition has completed.
        #expect(harness.arbiter.isNavigating)
        #expect(!harness.arbiter.gestureRecognizerShouldBegin(stack.pan))
        harness.beginReply(to: "0011")
        #expect(harness.replyTargets.isEmpty)
        #expect(harness.focusRequests == 0)
    }

    @Test func aCancelledPopRestoresAFocusedComposerWithoutMakingAReplyTarget() throws {
        let harness = ConversationPopHarness()
        harness.isComposerFocused = true
        let stack = try makeStack(harness: harness)
        defer { stack.window.isHidden = true }

        #expect(stack.controller.gestureRecognizerShouldBegin(stack.pop))
        #expect(harness.dismissRequests == 1)

        stack.controller.completeTransition(isCancelled: true)

        #expect(harness.focusRequests == 1)
        #expect(harness.replyTargets.isEmpty)
        #expect(!harness.isNavigating)
        #expect(!harness.arbiter.isNavigating)

        // The conversation is usable again: one reply, one focus request.
        harness.beginReply(to: "0011")
        #expect(harness.replyTargets == ["0011"])
        #expect(harness.focusRequests == 2)
    }

    @Test func aCancelledPopLeavesAnUnfocusedComposerAlone() throws {
        let harness = ConversationPopHarness()
        let stack = try makeStack(harness: harness)
        defer { stack.window.isHidden = true }

        #expect(stack.controller.gestureRecognizerShouldBegin(stack.pop))
        stack.controller.completeTransition(isCancelled: true)

        #expect(harness.dismissRequests == 1)
        #expect(harness.focusRequests == 0)
        #expect(!harness.isNavigating)
    }

    @Test func theArbiterRefusesRecognizersItCannotPlace() throws {
        let harness = ConversationPopHarness()
        let stack = try makeStack(harness: harness)
        defer { stack.window.isHidden = true }

        #expect(!harness.arbiter.gestureRecognizerShouldBegin(UITapGestureRecognizer()))
        // Detached from any view there is no frame to measure the edge against.
        #expect(!harness.arbiter.gestureRecognizerShouldBegin(UIPanGestureRecognizer()))
        #expect(ReplySwipeGestureArbiter.navigationPopRecognizer(for: UIPanGestureRecognizer()) == nil)
        #expect(!ReplySwipeGestureArbiter.ownsTouch(stack.pop))
    }

    @Test func onlyTheLeadingEdgeStripBelongsToNavigation() {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        #expect(ReplySwipe.isInLeadingEdgeNavigationRegion(
            startLocation: CGPoint(x: 0, y: 400), in: bounds
        ))
        #expect(ReplySwipe.isInLeadingEdgeNavigationRegion(
            startLocation: CGPoint(x: ReplySwipe.leadingEdgeNavigationWidth - 1, y: 400),
            in: bounds
        ))
        #expect(!ReplySwipe.isInLeadingEdgeNavigationRegion(
            startLocation: CGPoint(x: ReplySwipe.leadingEdgeNavigationWidth, y: 400),
            in: bounds
        ))
        #expect(!ReplySwipe.isInLeadingEdgeNavigationRegion(
            startLocation: CGPoint(x: 200, y: 400), in: bounds
        ))
        // A zero-width frame carries no edge, so it must not swallow the row.
        #expect(!ReplySwipe.isInLeadingEdgeNavigationRegion(
            startLocation: .zero, in: .zero
        ))
    }

    @Test func aReplySwipeStartedAwayFromTheEdgeStillFocusesTheComposerOnce() {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        let start = CGPoint(x: 180, y: 400)
        #expect(!ReplySwipe.isInLeadingEdgeNavigationRegion(startLocation: start, in: bounds))
        #expect(ReplySwipe.shouldBegin(velocity: CGPoint(x: 240, y: 30)))
        #expect(ReplySwipe.shouldActivate(translation: CGSize(width: 90, height: 8)))

        let harness = ConversationPopHarness()
        harness.beginReply(to: "0011")
        #expect(harness.replyTargets == ["0011"])
        #expect(harness.focusRequests == 1)
    }
}
