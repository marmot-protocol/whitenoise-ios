import SwiftUI
import UIKit

enum OnboardingSheetContent: Equatable {
    case welcome
    case signIn
    case signUp

    var prefersCompactHeight: Bool {
        self == .signIn
    }
}

/// Keep the label outside the glass material so disabled content is not dimmed twice.
struct WNOnboardingButton: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    let title: LocalizedStringKey
    var layoutTitle: LocalizedStringKey?
    var isLoading = false
    let action: () -> Void

    private var contentColor: Color {
        (isEnabled || isLoading) ? (colorScheme == .dark ? .black : .white) : Color(uiColor: .tertiaryLabel)
    }

    var body: some View {
        Button {
            guard isEnabled, !isLoading else { return }
            action()
        } label: {
            Text(layoutTitle ?? title).hidden().wnButtonLabelSizing(.large)
        }
        .wnPrimaryButtonStyle()
        .wnButtonChrome()
        .controlSize(.extraLarge)
        .wnButtonSizing()
        // Loading blocks activation without dimming the native button material.
        .environment(\.isEnabled, isEnabled || isLoading)
        .overlay {
            ZStack {
                Text(title).foregroundStyle(contentColor).opacity(isLoading ? 0 : 1)
                if isLoading {
                    ProgressView().controlSize(.small).tint(contentColor)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .allowsHitTesting(!isLoading)
        .accessibilityLabel(title)
        .accessibilityValue(isLoading ? Text("In progress") : Text(""))
    }
}
