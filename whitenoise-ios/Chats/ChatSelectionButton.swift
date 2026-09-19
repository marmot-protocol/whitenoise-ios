import SwiftUI
import UIKit

/// Selection actions share one circular size, independent of their glyph.
/// Native menus own layout and motion while the trigger changes to Close.
struct ChatSelectionButton: UIViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .body) private var diameter: CGFloat = 44
    let title: String
    let systemImage: String
    var isDestructive = false
    var action: (() -> Void)?
    var menu: (() -> [UIMenuElement])?

    func makeUIView(context: Context) -> MenuButton {
        let button = MenuButton(type: .system)
        var configuration: UIButton.Configuration
        if #available(iOS 26.0, *) {
            configuration = .glass()
        } else {
            configuration = .gray()
        }
        configuration.buttonSize = .large
        configuration.cornerStyle = .capsule
        configuration.baseForegroundColor = isDestructive ? .systemRed : .label
        configuration.image = UIImage(systemName: systemImage)
        button.configuration = configuration
        button.accessibilityLabel = title
        button.addAction(UIAction { [weak button] _ in button?.onPress?() }, for: .primaryActionTriggered)
        button.showsMenuAsPrimaryAction = menu != nil
        button.preferredMenuElementOrder = .fixed
        return button
    }

    func updateUIView(_ button: MenuButton, context: Context) {
        button.isEnabled = isEnabled
        if !isEnabled { button.contextMenuInteraction?.dismissMenu() }
        button.pendingUpdate = { [weak button] in
            guard let button else { return }
            updateButton(button)
        }
        button.applyPendingUpdateIfClosed()
    }

    private func updateButton(_ button: MenuButton) {
        button.baseTitle = title
        button.baseImage = systemImage
        button.onPress = action
        button.accessibilityLabel = title
        button.configuration?.image = UIImage(systemName: systemImage)
        button.configuration?.baseForegroundColor = isDestructive ? .systemRed : .label
        button.showsMenuAsPrimaryAction = menu != nil
        button.menu = menu.map { makeElements in
            UIMenu(children: [UIDeferredMenuElement.uncached { completion in
                completion(makeElements())
            }])
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: MenuButton, context: Context) -> CGSize? {
        CGSize(width: diameter, height: diameter)
    }

    static func dismantleUIView(_ button: MenuButton, coordinator: ()) {
        button.contextMenuInteraction?.dismissMenu()
    }

    final class MenuButton: UIButton {
        var baseTitle = ""
        var baseImage = ""
        var onPress: (() -> Void)?
        var pendingUpdate: (() -> Void)?
        private var isMenuPresented = false

        func applyPendingUpdateIfClosed() {
            guard !isMenuPresented else { return }
            let update = pendingUpdate
            pendingUpdate = nil
            update?()
        }

        override func menuAttachmentPoint(for configuration: UIContextMenuConfiguration) -> CGPoint {
            CGPoint(x: bounds.midX, y: bounds.minY)
        }

        override func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            willDisplayMenuFor configuration: UIContextMenuConfiguration,
            animator: (any UIContextMenuInteractionAnimating)?
        ) {
            isMenuPresented = true
            super.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: animator)
            updateSymbol(isOpen: true, animator: animator)
        }

        override func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            willEndFor configuration: UIContextMenuConfiguration,
            animator: (any UIContextMenuInteractionAnimating)?
        ) {
            super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
            updateSymbol(isOpen: false, animator: animator)
            let completion = { [weak self] in
                self?.isMenuPresented = false
                self?.applyPendingUpdateIfClosed()
            }
            if let animator {
                animator.addCompletion(completion)
            } else {
                completion()
            }
        }

        private func updateSymbol(isOpen: Bool, animator: (any UIContextMenuInteractionAnimating)?) {
            let update = { [weak self] in
                self?.configuration?.image = UIImage(systemName: isOpen ? "xmark" : (self?.baseImage ?? ""))
                self?.accessibilityLabel = isOpen ? L10n.string("Close") : self?.baseTitle
            }
            if let animator {
                animator.addAnimations(update)
            } else {
                update()
            }
        }
    }
}
