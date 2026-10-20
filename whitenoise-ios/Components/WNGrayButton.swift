import SwiftUI
import UIKit

/// UIKit's neutral gray surface for secondary actions inside content cards.
struct WNGrayButton: View {
    @Environment(\.isEnabled) private var isEnabled

    let title: String
    var isDestructive = false
    var isLoading = false
    let action: () -> Void

    var body: some View {
        ZStack {
            NativeGrayButton(
                title: title,
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

private struct NativeGrayButton: UIViewRepresentable {
    let title: String
    let isDestructive: Bool
    let isLoading: Bool
    let isEnabled: Bool
    let action: () -> Void

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(configuration: .gray())
        button.addTarget(context.coordinator, action: #selector(Coordinator.activate), for: .touchUpInside)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.action = action
        button.role = isDestructive ? .destructive : .normal
        button.isEnabled = isEnabled
        button.accessibilityLabel = title
        var configuration = UIButton.Configuration.gray()
        configuration.title = title
        configuration.buttonSize = .large
        configuration.cornerStyle = .capsule
        configuration.baseForegroundColor = isDestructive ? .systemRed : .label
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 15, leading: 20, bottom: 15, trailing: 20)
        configuration.titleLineBreakMode = .byWordWrapping
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var attributes = incoming
            attributes.font = .preferredFont(forTextStyle: .body)
            return attributes
        }
        button.configuration = configuration
        button.titleLabel?.alpha = isLoading ? 0 : 1
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.intrinsicContentSize.width
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(50, fitted.height))
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func activate() { action() }
    }
}
