import SwiftUI
import UIKit

struct ComposerTextInput: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let fontSize: CGFloat
    let focusRequest: Int
    let onPasteImage: (UIImage) -> Void
    var onBeginEditing: () -> Void = {}

    private let minimumHeight: CGFloat = BottomInputChromeLayout.controlSize
    private let maximumHeight: CGFloat = 112

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> ImagePasteTextView {
        let textView = ImagePasteTextView()
        textView.delegate = context.coordinator
        textView.onPasteImage = onPasteImage
        textView.backgroundColor = .clear
        textView.font = .systemFont(ofSize: fontSize)
        textView.textColor = .label
        textView.tintColor = UIColor(named: "AccentColor")
        textView.textContainerInset = UIEdgeInsets(
            top: BottomInputChromeLayout.fieldVerticalPadding,
            left: 0,
            bottom: BottomInputChromeLayout.fieldVerticalPadding,
            right: 0
        )
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.autocorrectionType = .default
        textView.autocapitalizationType = .sentences
        textView.keyboardDismissMode = .interactive
        textView.returnKeyType = .default
        textView.accessibilityLabel = L10n.string("Message")
        textView.isScrollEnabled = false
        return textView
    }

    func updateUIView(_ uiView: ImagePasteTextView, context: Context) {
        context.coordinator.parent = self
        uiView.onPasteImage = onPasteImage
        if uiView.text != text {
            uiView.text = text
            uiView.invalidateIntrinsicContentSize()
            uiView.updateScrollability(
                maximumHeight: maximumHeight,
                fittingWidth: uiView.bounds.width,
                revealSelection: uiView.isFirstResponder
            )
        }

        let receivedFocusRequest = focusRequest > context.coordinator.lastFocusRequest
        if receivedFocusRequest {
            context.coordinator.lastFocusRequest = focusRequest
        }

        if isFocused || receivedFocusRequest {
            if !uiView.isFirstResponder {
                context.coordinator.scheduleFocus(
                    for: uiView,
                    promoteBinding: receivedFocusRequest
                )
            }
        } else {
            context.coordinator.cancelPendingFocus()
            if !isFocused, uiView.isFirstResponder {
                uiView.resignFirstResponder()
            }
        }
    }

    static func dismantleUIView(_ uiView: ImagePasteTextView, coordinator: Coordinator) {
        coordinator.cancelPendingFocus()
        uiView.resignFirstResponder()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: ImagePasteTextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let fittingHeight = uiView.updateScrollability(
            maximumHeight: maximumHeight,
            fittingWidth: width,
            revealSelection: false
        )
        let height = min(maximumHeight, max(minimumHeight, fittingHeight))
        return CGSize(width: width, height: height)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextInput
        var lastFocusRequest: Int
        private var pendingFocusTask: Task<Void, Never>?

        init(parent: ComposerTextInput) {
            self.parent = parent
            self.lastFocusRequest = 0
        }

        func scheduleFocus(
            for textView: ImagePasteTextView,
            promoteBinding: Bool = false
        ) {
            guard pendingFocusTask == nil else { return }
            pendingFocusTask = Task { @MainActor [weak self, weak textView] in
                guard let self else { return }
                defer { pendingFocusTask = nil }
                if promoteBinding, !parent.isFocused {
                    parent.isFocused = true
                    await Task.yield()
                }
                guard !Task.isCancelled,
                      parent.isFocused,
                      let textView,
                      !textView.isFirstResponder
                else { return }
                textView.becomeFirstResponder()
            }
        }

        func cancelPendingFocus() {
            pendingFocusTask?.cancel()
            pendingFocusTask = nil
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            textView.invalidateIntrinsicContentSize()
            guard let textView = textView as? ImagePasteTextView else { return }
            textView.updateScrollability(
                maximumHeight: parent.maximumHeight,
                fittingWidth: textView.bounds.width,
                revealSelection: true
            )
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.isFocused = true
            parent.onBeginEditing()
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.isFocused = false
        }
    }
}

final class ImagePasteTextView: UITextView {
    var onPasteImage: ((UIImage) -> Void)?

    @discardableResult
    func updateScrollability(
        maximumHeight: CGFloat,
        fittingWidth: CGFloat,
        revealSelection: Bool
    ) -> CGFloat {
        guard fittingWidth > 0 else { return contentSize.height }
        let fittingHeight = sizeThatFits(
            CGSize(width: fittingWidth, height: .greatestFiniteMagnitude)
        ).height
        let shouldScroll = fittingHeight > maximumHeight
        if isScrollEnabled != shouldScroll {
            isScrollEnabled = shouldScroll
        }
        if shouldScroll, revealSelection {
            scrollRangeToVisible(selectedRange)
        }
        return fittingHeight
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), UIPasteboard.general.hasImages {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        if let image = UIPasteboard.general.image {
            onPasteImage?(image)
            return
        }
        super.paste(sender)
    }
}
