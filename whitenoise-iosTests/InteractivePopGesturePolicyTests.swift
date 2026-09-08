import Testing
@testable import whitenoise_ios

struct InteractivePopGesturePolicyTests {
    @Test func beginsOnceSomethingIsPushedAboveTheRoot() {
        #expect(InteractivePopGesturePolicy.shouldBegin(stackDepth: 2, isTransitioning: false))
        #expect(InteractivePopGesturePolicy.shouldBegin(stackDepth: 5, isTransitioning: false))
    }

    @Test func neverPopsTheRootController() {
        #expect(!InteractivePopGesturePolicy.shouldBegin(stackDepth: 1, isTransitioning: false))
        #expect(!InteractivePopGesturePolicy.shouldBegin(stackDepth: 0, isTransitioning: false))
    }

    @Test func neverStartsASecondPopMidTransition() {
        #expect(!InteractivePopGesturePolicy.shouldBegin(stackDepth: 2, isTransitioning: true))
        #expect(!InteractivePopGesturePolicy.shouldBegin(stackDepth: 1, isTransitioning: true))
    }
}
