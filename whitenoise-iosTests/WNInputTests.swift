import SwiftUI
import Testing
@testable import whitenoise_ios

struct WNInputTests {
    @Test func singleLineKindsAreCapsules() {
        #expect(WNInputMetrics.shape(for: .text) == .capsule)
        #expect(WNInputMetrics.shape(for: .secure) == .capsule)
    }

    @Test func multilineTradesTheCapsuleForAContinuousRadius() {
        #expect(
            WNInputMetrics.shape(for: .multiline(1 ... 4))
                == .rounded(WNInputMetrics.multilineCornerRadius)
        )
    }

    @Test func oneLineMultilineIsIndistinguishableFromACapsule() {
        let collapsed = WNInputMetrics.height
        guard case .rounded(let radius) = WNInputMetrics.shape(for: .multiline(1 ... 4)) else {
            Issue.record("multiline should be a rounded shape")
            return
        }
        #expect(radius * 2 == collapsed)
    }

    @Test func onlySingleLineKindsPinTheCapsuleHeight() {
        #expect(WNInputMetrics.fixesHeight(for: .text))
        #expect(WNInputMetrics.fixesHeight(for: .secure))
        #expect(!WNInputMetrics.fixesHeight(for: .multiline(2 ... 5)))
    }

    @Test func onlyMultilineAddsVerticalPaddingBecauseItHasNoFixedHeight() {
        #expect(WNInputMetrics.verticalInset(for: .text) == 0)
        #expect(WNInputMetrics.verticalInset(for: .secure) == 0)
        #expect(
            WNInputMetrics.verticalInset(for: .multiline(2 ... 5))
                == WNInputMetrics.multilineVerticalInset
        )
    }

    @Test func accessoryTargetClearsTheAppleMinimumTapTarget() {
        #expect(WNInputMetrics.accessoryTarget >= 44)
    }
}
