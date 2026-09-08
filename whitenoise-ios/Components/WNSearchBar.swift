import SwiftUI

/// A search field pinned to the bottom of a screen, with the control that
/// closes it beside the field.
///
/// iOS 26 can integrate a native search field into the bottom toolbar, but
/// `SearchFieldPlacement` offers nothing below the navigation bar before then
/// — and on activation UIKit takes over the navigation bar, hiding whatever
/// exit the app put there. So the bar is drawn here instead, and the ✕ travels
/// with the field.
///
/// Chrome comes from the shared bottom-input seam, so the pill is Liquid Glass
/// on iOS 26 and a material capsule below it, refracting together with the ✕
/// rather than each sampling its own backdrop.
struct WNSearchBar: View {
    nonisolated enum Metrics {
        /// Matches the composer's bottom row so the two surfaces line up.
        static let horizontalInset: CGFloat = 16
        static let verticalInset: CGFloat = 6
        static let rowSpacing: CGFloat = 8
        static let fieldHeight: CGFloat = 44
    }

    nonisolated enum Palette {
        /// The magnifier labels the field you are about to type in, so it
        /// reads at label weight; `.secondary` under-weights it against the
        /// text that lands beside it.
        static let fieldGlyph = Color.primary

        /// The clear control is the same accent-filled circle as every WN
        /// icon button, with the glyph knocked out in the surface colour, so
        /// it inverts between appearances instead of staying a dark circle on
        /// a dark field.
        static func clearFill(for colorScheme: ColorScheme) -> Color {
            WNButton.Metrics.accent(for: colorScheme)
        }

        static func clearGlyph(for colorScheme: ColorScheme) -> Color {
            WNButton.Metrics.contentColor(
                emphasis: .primary,
                colorScheme: colorScheme,
                isEnabled: true
            )
        }
    }

    @Binding var query: String
    let prompt: LocalizedStringKey
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        bottomInputGlassContainer(spacing: Metrics.rowSpacing) {
            HStack(spacing: Metrics.rowSpacing) {
                field
                WNIconButton(title: "Close search", systemImage: "xmark", action: onClose)
            }
        }
        // No bar behind the row: the glass has to sample the list scrolling
        // under it, the way the composer floats over the timeline.
        .padding(.horizontal, Metrics.horizontalInset)
        .padding(.vertical, Metrics.verticalInset)
        .onAppear {
            // Focus after the inset has been laid out, or the keyboard rises
            // into a bar that has not claimed its height yet.
            Task { @MainActor in
                await Task.yield()
                isFieldFocused = true
            }
        }
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Palette.fieldGlyph)
            TextField("", text: $query, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .font(.body)
                .submitLabel(.search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isFieldFocused)
                .onSubmit { isFieldFocused = false }
            if !query.isEmpty {
                Button {
                    query = ""
                    isFieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(
                            Palette.clearGlyph(for: colorScheme),
                            Palette.clearFill(for: colorScheme)
                        )
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, BottomInputChromeLayout.fieldLeadingPadding)
        .padding(.trailing, BottomInputChromeLayout.fieldTrailingPadding)
        .frame(minHeight: Metrics.fieldHeight)
        .compatibleInputCapsuleChrome()
    }
}

#Preview("WNSearchBar — empty") {
    @Previewable @State var query = ""
    VStack {
        Spacer()
        WNSearchBar(query: $query, prompt: "Search Chats") {}
    }
    .background(.background)
}

#Preview("WNSearchBar — typed") {
    @Previewable @State var query = "marmota"
    VStack {
        Spacer()
        WNSearchBar(query: $query, prompt: "Search Chats") {}
    }
    .background(.background)
    .preferredColorScheme(.dark)
}
