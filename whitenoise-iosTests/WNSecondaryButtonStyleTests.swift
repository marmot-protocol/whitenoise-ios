import SwiftUI
import Testing
@testable import whitenoise_ios

struct WNSecondaryButtonStyleTests {
    private typealias Metrics = WNSecondaryButtonStyle.Metrics

    @Test func paddingKeepsAWiderThanTallPill() {
        for controlSize in ControlSize.allCases {
            #expect(Metrics.verticalPadding(for: controlSize) > 0)
            #expect(Metrics.horizontalPadding > Metrics.verticalPadding(for: controlSize))
        }
    }

    @Test func theCapsuleKeepsItsPaddingWhileTheCircleSizesFromItsDiameter() {
        for controlSize in ControlSize.allCases {
            let capsule = Metrics.insets(for: .capsule, controlSize: controlSize)
            #expect(capsule.horizontal == Metrics.horizontalPadding)
            #expect(capsule.vertical == Metrics.verticalPadding(for: controlSize))

            // Padding would stretch a bare glyph off center, so the circle
            // takes its size from the frame instead.
            let circle = Metrics.insets(for: .circle, controlSize: controlSize)
            #expect(circle.horizontal == 0)
            #expect(circle.vertical == 0)
        }
    }

    @Test func circleDiameterClearsTheAppleMinimumTapTarget() {
        #expect(Metrics.circleDiameter >= 44)
    }
}
