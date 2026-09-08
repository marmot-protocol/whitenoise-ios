import SwiftUI
import UIKit

/// Equal-width primary action for the details header rows (Add, Mute,
/// Search…). Icon over a short label, minimum 44-point target.
enum DetailsActionButtonAppearance {
    case bordered
    case circular
}

struct DetailsActionButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    var isDisabled = false
    var isLoading = false
    var appearance: DetailsActionButtonAppearance = .bordered
    let action: () -> Void

    @ViewBuilder
    var body: some View {
        switch appearance {
        case .bordered:
            Button(action: action) {
                label
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.bordered)
            .disabled(isDisabled || isLoading)
        case .circular:
            VStack(spacing: 6) {
                Button(action: action) {
                    icon
                        .frame(width: 44, height: 44)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .circle)
                        .overlay {
                            Circle().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                        }
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .disabled(isDisabled || isLoading)
                .accessibilityLabel(title)

                Text(title)
                    .font(.footnote)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity)
            .opacity(isDisabled ? 0.45 : 1)
        }
    }

    private var label: some View {
        VStack(spacing: 4) {
            icon
            Text(title)
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    @ViewBuilder
    private var icon: some View {
        Group {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
            }
        }
        .accessibilityHidden(true)
    }
}
