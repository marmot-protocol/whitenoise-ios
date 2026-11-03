import SwiftUI
import UIKit

/// UIKit's neutral gray surface for secondary actions inside content cards.
struct WNGrayButton: View {
    @Environment(\.isEnabled) private var isEnabled

    let title: String
    var systemImage: String? = nil
    var isDestructive = false
    var isLoading = false
    let action: () -> Void

    var body: some View {
        ZStack {
            NativeGrayButton(
                title: title,
                systemImage: systemImage,
                isDestructive: isDestructive,
                isLoading: isLoading,
                isEnabled: isEnabled && !isLoading,
                action: action
            )
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(isDestructive ? .red : .primary)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 50)
    }
}

/// A flat accessory matching the surface and height of an input on the page background.
struct WNInputIconButton: View {
    @Environment(\.isEnabled) private var isEnabled

    let title: String
    let systemImage: String
    var isLoading = false
    let action: () -> Void

    var body: some View {
        ZStack {
            NativeGrayButton(
                title: title,
                systemImage: systemImage,
                isDestructive: false,
                isLoading: isLoading,
                isEnabled: isEnabled && !isLoading,
                action: action,
                showsTitle: false,
                backgroundColor: .secondarySystemGroupedBackground
            )
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(.primary)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: WNInputMetrics.height, height: WNInputMetrics.height)
    }
}

private struct NativeGrayButton: UIViewRepresentable {
    let title: String
    let systemImage: String?
    let isDestructive: Bool
    let isLoading: Bool
    let isEnabled: Bool
    let action: () -> Void
    var showsTitle = true
    var backgroundColor: UIColor? = nil

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(configuration: .gray())
        button.addTarget(context.coordinator, action: #selector(Coordinator.activate), for: .touchUpInside)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.action = action
        let content = ConfigurationContent(
            title: title,
            systemImage: systemImage,
            isDestructive: isDestructive,
            isLoading: isLoading,
            showsTitle: showsTitle,
            backgroundColor: backgroundColor,
            contentSizeCategory: button.traitCollection.preferredContentSizeCategory
        )
        let contentChanged = context.coordinator.content != content
        guard contentChanged || button.isEnabled != isEnabled else { return }

        // Modal updates must not reinstall unchanged labels or animate a brief
        // disabled/enabled transition underneath the sheet.
        UIView.performWithoutAnimation {
            if contentChanged {
                button.role = isDestructive ? .destructive : .normal
                button.accessibilityLabel = title
                button.configuration = makeConfiguration()
                context.coordinator.content = content
            }
            button.isEnabled = isEnabled
            button.updateConfiguration()
            button.layoutIfNeeded()
        }
    }

    private func makeConfiguration() -> UIButton.Configuration {
        var configuration: UIButton.Configuration = backgroundColor == nil ? .gray() : .filled()
        if let backgroundColor {
            configuration.baseBackgroundColor = backgroundColor
        }
        configuration.title = showsTitle ? title : nil
        if let systemImage {
            configuration.image = UIImage(systemName: systemImage)
            configuration.imagePadding = showsTitle ? 8 : 0
            configuration.preferredSymbolConfigurationForImage = showsTitle
                ? UIImage.SymbolConfiguration(textStyle: .body)
                : UIImage.SymbolConfiguration(textStyle: .body, scale: .small)
                    .applying(UIImage.SymbolConfiguration(weight: .regular))
        }
        configuration.buttonSize = .large
        configuration.cornerStyle = .capsule
        configuration.baseForegroundColor = isDestructive ? .systemRed : .label
        configuration.contentInsets = showsTitle
            ? NSDirectionalEdgeInsets(top: 15, leading: 20, bottom: 15, trailing: 20)
            : .zero
        configuration.titleLineBreakMode = .byWordWrapping
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { [isLoading] incoming in
            var attributes = incoming
            attributes.font = .preferredFont(forTextStyle: .body)
            if isLoading { attributes.foregroundColor = .clear }
            return attributes
        }
        // Keep the label's geometry while loading, but let the configuration own
        // its appearance. UIKit also updates these subviews during state changes.
        if isLoading {
            configuration.imageColorTransformer = UIConfigurationColorTransformer { _ in .clear }
        }
        return configuration
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.intrinsicContentSize.width
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(50, fitted.height))
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    struct ConfigurationContent: Equatable {
        let title: String
        let systemImage: String?
        let isDestructive: Bool
        let isLoading: Bool
        let showsTitle: Bool
        let backgroundColor: UIColor?
        let contentSizeCategory: UIContentSizeCategory
    }

    final class Coordinator {
        var action: () -> Void
        var content: ConfigurationContent?
        init(action: @escaping () -> Void) { self.action = action }
        @objc func activate() { action() }
    }
}
