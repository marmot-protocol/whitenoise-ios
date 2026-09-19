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
            DetailsQuickAction(title: title, size: .compact) {
                Button(action: action) { icon }
                    .disabled(isDisabled || isLoading)
            }
            .frame(maxWidth: .infinity)
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

struct DetailsQuickAction<Control: View>: View {
    enum Size {
        case compact
        case regular

        var diameter: CGFloat { self == .compact ? 44 : 64 }
        var font: Font { self == .compact ? .body.weight(.semibold) : .title3 }
    }

    let title: LocalizedStringKey
    var size = Size.regular
    @ViewBuilder let control: () -> Control

    var body: some View {
        VStack(spacing: 6) {
            control()
                .buttonStyle(DetailsQuickActionStyle(diameter: size.diameter, font: size.font))
                .accessibilityLabel(title)
            Text(title)
                .font(.footnote)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityHidden(true)
        }
    }
}

private struct DetailsQuickActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    let diameter: CGFloat
    let font: Font

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .foregroundStyle(.primary)
            .frame(width: diameter, height: diameter)
            .background(
                Color(uiColor: configuration.isPressed ? .secondarySystemFill : .secondarySystemGroupedBackground),
                in: Circle()
            )
            .overlay {
                Circle().stroke(Color(uiColor: .separator).opacity(0.35), lineWidth: 0.5)
            }
            .opacity(isEnabled ? 1 : 0.45)
    }
}
