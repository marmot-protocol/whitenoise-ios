import SwiftUI

/// Keeps supporting text close to its input and aligned with the capsule text.
struct WNInputWithFooter<Input: View, Footer: View>: View {
    @ViewBuilder var input: () -> Input
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            input()
            footer()
        }
    }
}

extension View {
    /// Apply to helper text outside a native section footer, never to the input.
    func wnInputFooter(isError: Bool = false) -> some View {
        font(.footnote)
            .foregroundStyle(isError ? Color.red : Color.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, WNInputMetrics.leadingInset)
    }
}
