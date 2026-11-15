import SwiftUI
import UIKit

/// Hold-to-dictate on the message field while the keyboard is down.
struct ComposerDictationGesture {
    /// The hold began. Receives the language of the keyboard last used here
    /// and where the finger is, in window coordinates.
    var onBegan: (_ keyboardLanguage: String?, _ location: CGPoint) -> Void
    /// The finger moved, measured from where the hold began.
    var onChanged: (CGSize) -> Void
    var onEnded: () -> Void
    /// The system took the touch (a call, an alert): discard, never send.
    var onCancelled: () -> Void
    /// VoiceOver's Dictate action, which starts hands-free dictation.
    var onAccessibilityDictate: (_ keyboardLanguage: String?) -> Void
}

nonisolated enum ComposerDictationGesturePolicy {
    static let minimumPressDuration: TimeInterval = 0.3

    enum Event: Equatable {
        case began
        case changed
        case ended
        case cancelled
    }

    /// Only a lifted finger finishes; a hold UIKit cancels is discarded.
    static func event(for state: UIGestureRecognizer.State) -> Event? {
        switch state {
        case .began: .began
        case .changed: .changed
        case .ended: .ended
        case .cancelled: .cancelled
        default: nil
        }
    }

    /// A focused field keeps the system's hold-to-move-the-cursor gesture.
    static func admitsHold(isAvailable: Bool, isEditing: Bool) -> Bool {
        isAvailable && !isEditing
    }
}

/// The message field: the text view, plus a surface over it while the
/// keyboard is down that owns hold-to-dictate and tap-to-type. The surface
/// keeps the touch away from the text view, whose own tap and drag gestures
/// would otherwise hold a dictation hold back until the finger moved.
final class ComposerTextInputContainer: UIView {
    let textView = ImagePasteTextView()
    let restingSurface = ComposerRestingSurface()

    override init(frame: CGRect) {
        super.init(frame: frame)
        textView.frame = bounds
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(textView)
        restingSurface.frame = bounds
        restingSurface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        restingSurface.isHidden = true
        addSubview(restingSurface)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// A control, so the window's tap-to-dismiss-keyboard gesture leaves it alone.
final class ComposerRestingSurface: UIControl {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

struct ComposerTextInput: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let fontSize: CGFloat
    let focusRequest: Int
    let onPasteImage: (UIImage) -> Void
    var onBeginEditing: () -> Void = {}
    var dictation: ComposerDictationGesture?
    /// Dictation owns the field; a tap must not raise the keyboard under it.
    var blocksEditing = false

    private let minimumHeight: CGFloat = BottomInputChromeLayout.controlSize
    private let maximumHeight: CGFloat = 112

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> ComposerTextInputContainer {
        let container = ComposerTextInputContainer()
        let textView = container.textView
        textView.maximumComposerHeight = maximumHeight
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
        context.coordinator.install(on: container)
        return container
    }

    func updateUIView(_ container: ComposerTextInputContainer, context: Context) {
        let uiView = container.textView
        context.coordinator.parent = self
        uiView.onPasteImage = onPasteImage
        context.coordinator.updateDictationAvailability()
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

    static func dismantleUIView(_ container: ComposerTextInputContainer, coordinator: Coordinator) {
        coordinator.cancelPendingFocus()
        container.textView.resignFirstResponder()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView container: ComposerTextInputContainer,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let fittingHeight = container.textView.naturalContentHeight(fittingWidth: width)
        let height = min(maximumHeight, max(minimumHeight, fittingHeight))
        return CGSize(width: width, height: height)
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: ComposerTextInput
        var lastFocusRequest: Int
        private weak var container: ComposerTextInputContainer?
        private weak var dictationPress: UILongPressGestureRecognizer?
        private var pendingFocusTask: Task<Void, Never>?
        private var lastKeyboardLanguage: String?
        private var dictationPressOrigin: CGPoint = .zero
        private var dictationActionInstalled = false

        init(parent: ComposerTextInput) {
            self.parent = parent
            self.lastFocusRequest = 0
        }

        func install(on container: ComposerTextInputContainer) {
            self.container = container
            let press = UILongPressGestureRecognizer(target: self, action: #selector(handleDictationPress(_:)))
            press.minimumPressDuration = ComposerDictationGesturePolicy.minimumPressDuration
            press.delegate = self
            container.restingSurface.addGestureRecognizer(press)
            dictationPress = press
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleRestingTap(_:)))
            container.restingSurface.addGestureRecognizer(tap)
            updateDictationAvailability()
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

        /// The surface covers the field only while the keyboard is down and
        /// dictation is offered, and stays for a hold already under way.
        func updateDictationAvailability() {
            guard let container else { return }
            let textView = container.textView
            let holding = dictationPress?.state == .began || dictationPress?.state == .changed
            container.restingSurface.isHidden = !(holding || ComposerDictationGesturePolicy.admitsHold(
                isAvailable: parent.dictation != nil,
                isEditing: textView.isFirstResponder
            ))
            let wantsAction = parent.dictation != nil
            guard wantsAction != dictationActionInstalled else { return }
            dictationActionInstalled = wantsAction
            textView.accessibilityCustomActions = wantsAction
                ? [UIAccessibilityCustomAction(name: L10n.string("Dictate")) { [weak self] _ in
                    guard let self, let dictation = self.parent.dictation else { return false }
                    dictation.onAccessibilityDictate(self.lastKeyboardLanguage)
                    return true
                }]
                : nil
        }

        @objc private func handleDictationPress(_ recognizer: UILongPressGestureRecognizer) {
            let location = recognizer.location(in: nil)
            switch ComposerDictationGesturePolicy.event(for: recognizer.state) {
            case .began:
                dictationPressOrigin = location
                parent.dictation?.onBegan(lastKeyboardLanguage, location)
            case .changed:
                parent.dictation?.onChanged(CGSize(
                    width: location.x - dictationPressOrigin.x,
                    height: location.y - dictationPressOrigin.y
                ))
            case .ended:
                // A fast slide can land past the cancel point only on release.
                parent.dictation?.onChanged(CGSize(
                    width: location.x - dictationPressOrigin.x,
                    height: location.y - dictationPressOrigin.y
                ))
                parent.dictation?.onEnded()
                updateDictationAvailability()
            case .cancelled:
                parent.dictation?.onCancelled()
                updateDictationAvailability()
            case nil:
                break
            }
        }

        /// A tap types, with the caret where the finger landed, as the text
        /// view itself would.
        @objc private func handleRestingTap(_ recognizer: UITapGestureRecognizer) {
            guard let textView = container?.textView,
                  recognizer.state == .ended,
                  textView.becomeFirstResponder()
            else { return }
            let point = recognizer.location(in: textView)
            if let position = textView.closestPosition(to: point) {
                textView.selectedTextRange = textView.textRange(from: position, to: position)
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === dictationPress, let textView = container?.textView else { return true }
            return ComposerDictationGesturePolicy.admitsHold(
                isAvailable: parent.dictation != nil,
                isEditing: textView.isFirstResponder
            )
        }

        func textViewShouldBeginEditing(_ textView: UITextView) -> Bool {
            !parent.blocksEditing
        }

        private func rememberKeyboardLanguage(of textView: UITextView) {
            if let language = textView.textInputMode?.primaryLanguage {
                lastKeyboardLanguage = language
            }
        }

        func textViewDidChange(_ textView: UITextView) {
            rememberKeyboardLanguage(of: textView)
            parent.text = textView.text
            textView.invalidateIntrinsicContentSize()
            guard let textView = textView as? ImagePasteTextView else { return }
            textView.updateScrollability(
                maximumHeight: parent.maximumHeight,
                fittingWidth: textView.bounds.width,
                revealSelection: true
            )
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            (textView as? ImagePasteTextView)?.revealSelectionAfterLayout()
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            rememberKeyboardLanguage(of: textView)
            updateDictationAvailability()
            parent.isFocused = true
            parent.onBeginEditing()
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            rememberKeyboardLanguage(of: textView)
            updateDictationAvailability()
            parent.isFocused = false
        }
    }
}

final class ImagePasteTextView: UITextView {
    var onPasteImage: ((UIImage) -> Void)?
    var maximumComposerHeight: CGFloat = 112
    private var needsSelectionReveal = false

    func naturalContentHeight(fittingWidth: CGFloat) -> CGFloat {
        guard fittingWidth.isFinite, fittingWidth > 0 else { return contentSize.height }
        return sizeThatFits(CGSize(width: fittingWidth, height: .greatestFiniteMagnitude)).height
    }

    func revealSelectionAfterLayout() {
        needsSelectionReveal = true
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // SwiftUI probes several widths; only the installed viewport decides scrolling.
        updateScrollability(maximumHeight: maximumComposerHeight, fittingWidth: bounds.width, revealSelection: false)
        guard needsSelectionReveal else { return }
        needsSelectionReveal = false
        guard isScrollEnabled, let selection = selectedTextRange else { return }
        let caret = caretRect(for: selection.end).insetBy(dx: 0, dy: -textContainerInset.bottom)
        scrollRectToVisible(caret, animated: false)
    }

    @discardableResult
    func updateScrollability(
        maximumHeight: CGFloat,
        fittingWidth: CGFloat,
        revealSelection: Bool
    ) -> CGFloat {
        maximumComposerHeight = maximumHeight
        guard fittingWidth.isFinite, fittingWidth > 0 else { return contentSize.height }
        let fittingHeight = naturalContentHeight(fittingWidth: fittingWidth)
        let shouldScroll = fittingHeight > maximumHeight
        if isScrollEnabled != shouldScroll {
            isScrollEnabled = shouldScroll
        }
        if revealSelection { revealSelectionAfterLayout() }
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
