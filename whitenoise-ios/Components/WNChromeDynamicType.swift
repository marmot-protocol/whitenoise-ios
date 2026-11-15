import SwiftUI
import UIKit

/// Bar and composer controls stop growing at `maximum`, the way system bars
/// do, so at accessibility sizes they leave room for the text beside them.
/// Past it, a long press shows the control in the Large Content Viewer.
nonisolated enum WNChromeDynamicType {
    static let maximum: DynamicTypeSize = .xxxLarge

    static func capped(_ size: DynamicTypeSize) -> DynamicTypeSize {
        min(size, maximum)
    }

    /// `@ScaledMetric` with the cap applied: `value` scaled for `size`, but no
    /// further than it scales at `maximum`.
    static func scaled(
        _ value: CGFloat,
        relativeTo textStyle: UIFont.TextStyle = .body,
        at size: DynamicTypeSize
    ) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(capped(size)))
        return UIFontMetrics(forTextStyle: textStyle).scaledValue(for: value, compatibleWith: traits)
    }
}

extension View {
    /// Caps a control at `WNChromeDynamicType.maximum` and lets a long press
    /// show it enlarged instead.
    func wnChromeDynamicType() -> some View {
        dynamicTypeSize(...WNChromeDynamicType.maximum)
            .accessibilityShowsLargeContentViewer()
    }
}
