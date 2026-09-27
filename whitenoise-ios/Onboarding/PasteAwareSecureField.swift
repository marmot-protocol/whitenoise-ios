import SwiftUI
import UIKit

struct PasteAwareSecureField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let showsAccessory: Bool
    var onFocusRequest: () -> Void = {}
    let onPaste: (SensitiveClipboard.Token?, String) -> Void
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            isFocused: $isFocused,
            onSubmit: onSubmit,
            onFocusRequest: onFocusRequest
        )
    }

    func makeUIView(context: Context) -> PasteInterceptingSecureTextField {
        let field = PasteInterceptingSecureTextField()
        field.delegate = context.coordinator
        field.pasteDelegate = field
        field.configureAccessory()
        field.onPaste = onPaste
        field.isSecureTextEntry = true
        field.placeholder = L10n.string("Enter private key")
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartInsertDeleteType = .no
        field.textContentType = .password
        field.returnKeyType = .go
        field.adjustsFontForContentSizeCategory = true
        field.font = UIFont.preferredFont(forTextStyle: .body)
        field.onTextMutation = { [weak coordinator = context.coordinator] field in
            coordinator?.textChanged(field)
        }
        context.coordinator.syncedText = text
        field.text = text
        return field
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: PasteInterceptingSecureTextField,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width.isFinite else { return nil }
        // Long keys scroll inside the field instead of widening the form.
        return CGSize(width: width, height: max(44, uiView.intrinsicContentSize.height))
    }

    func updateUIView(_ field: PasteInterceptingSecureTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.update(text: $text, isFocused: $isFocused, onSubmit: onSubmit, onFocusRequest: onFocusRequest)
        field.onPaste = onPaste
        if text != coordinator.syncedText {
            coordinator.syncedText = text
            if field.text != text { field.text = text }
        }
        coordinator.requestFocus(isFocused, for: field)
        field.setAccessoryVisible(showsAccessory)
    }

    static func dismantleUIView(_ field: PasteInterceptingSecureTextField, coordinator: Coordinator) {
        coordinator.cancelPendingFocus()
        field.cancelPendingAccessoryUpdate()
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        @Binding private var text: String
        @Binding private var isFocused: Bool
        private var onSubmit: () -> Void
        private var onFocusRequest: () -> Void
        var syncedText = ""
        private var requestedFocus = false
        private var pendingFocus: Task<Void, Never>?

        init(
            text: Binding<String>,
            isFocused: Binding<Bool>,
            onSubmit: @escaping () -> Void,
            onFocusRequest: @escaping () -> Void
        ) {
            _text = text
            _isFocused = isFocused
            self.onSubmit = onSubmit
            self.onFocusRequest = onFocusRequest
        }

        func update(text: Binding<String>, isFocused: Binding<Bool>, onSubmit: @escaping () -> Void, onFocusRequest: @escaping () -> Void) {
            _text = text
            _isFocused = isFocused
            self.onSubmit = onSubmit
            self.onFocusRequest = onFocusRequest
        }

        func textChanged(_ field: UITextField) {
            let value = field.text ?? ""
            guard value != syncedText else { return }
            syncedText = value
            text = value
        }

        func requestFocus(_ wantsFocus: Bool, for field: UITextField) {
            guard wantsFocus != requestedFocus else { return }
            requestedFocus = wantsFocus
            pendingFocus?.cancel()
            pendingFocus = Task { @MainActor [weak self, weak field] in
                guard let self, let field, !Task.isCancelled else { return }
                pendingFocus = nil
                if requestedFocus, !field.isFirstResponder {
                    field.becomeFirstResponder()
                } else if !requestedFocus, field.isFirstResponder {
                    field.resignFirstResponder()
                }
                reportFocus(field.isFirstResponder)
            }
        }

        func cancelPendingFocus() {
            pendingFocus?.cancel()
            pendingFocus = nil
        }

        private func reportFocus(_ focused: Bool) {
            requestedFocus = focused
            if isFocused != focused { isFocused = focused }
        }

        func textFieldShouldBeginEditing(_ textField: UITextField) -> Bool {
            onFocusRequest()
            return true
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            textChanged(textField)
            reportFocus(true)
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            textChanged(textField)
            reportFocus(false)
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            onSubmit()
            return true
        }
    }
}

final class PasteInterceptingSecureTextField: UITextField, UITextPasteDelegate {
    var onPaste: ((SensitiveClipboard.Token?, String) -> Void)?
    var onTextMutation: ((PasteInterceptingSecureTextField) -> Void)?
    private var pendingPasteToken: SensitiveClipboard.Token?
    private static let pasteTokenAttribute = NSAttributedString.Key("WhiteNoisePasteToken")
    private var pasteControl: UIPasteControl?
    private let visibilityButton = UIButton(type: .system)
    private var accessoryVisible = true
    private var pendingAccessoryUpdate: Task<Void, Never>?

    override var text: String? {
        didSet { textDidMutate() }
    }

    override var attributedText: NSAttributedString? {
        didSet { textDidMutate() }
    }

    @objc private func textDidMutate() {
        scheduleAccessoryUpdate()
        onTextMutation?(self)
    }

    func configureAccessory(notificationCenter: NotificationCenter = .default) {
        isSecureTextEntry = true
        notificationCenter.addObserver(self, selector: #selector(hidePrivateKey),
                                       name: UIApplication.willResignActiveNotification, object: nil)
        pasteConfiguration = UIPasteConfiguration(forAccepting: NSString.self)
        rebuildPasteControl()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitUserInterfaceLevel.self]) {
            (field: PasteInterceptingSecureTextField, _: UITraitCollection) in
            field.rebuildPasteControl()
        }
        visibilityButton.tintColor = .label
        visibilityButton.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(textStyle: .body, scale: .medium),
            forImageIn: .normal
        )
        visibilityButton.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        visibilityButton.addTarget(self, action: #selector(togglePrivateKeyVisibility), for: .touchUpInside)
        addTarget(self, action: #selector(textDidMutate), for: .editingChanged)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textDidMutate),
            name: UITextField.textDidChangeNotification,
            object: self
        )
        applyAccessory()
    }

    private func rebuildPasteControl() {
        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconOnly
        configuration.baseBackgroundColor = opaqueInputFill
        configuration.cornerStyle = .capsule
        configuration.baseForegroundColor = UIColor.label.resolvedColor(with: traitCollection)
        let control = UIPasteControl(configuration: configuration)
        control.target = self
        control.accessibilityLabel = L10n.string("Paste")
        control.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        pasteControl = control
        scheduleAccessoryUpdate()
    }

    private var opaqueInputFill: UIColor {
        // Native paste controls need opaque colors, resolved for their current appearance.
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        var baseRed: CGFloat = 0, baseGreen: CGFloat = 0, baseBlue: CGFloat = 0, baseAlpha: CGFloat = 0
        UIColor.secondarySystemFill.resolvedColor(with: traitCollection)
            .getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        UIColor.systemBackground.resolvedColor(with: traitCollection)
            .getRed(&baseRed, green: &baseGreen, blue: &baseBlue, alpha: &baseAlpha)
        return UIColor(red: red * alpha + baseRed * (1 - alpha),
                       green: green * alpha + baseGreen * (1 - alpha),
                       blue: blue * alpha + baseBlue * (1 - alpha), alpha: 1)
    }

    func setAccessoryVisible(_ visible: Bool) {
        accessoryVisible = visible
        scheduleAccessoryUpdate()
    }

    func cancelPendingAccessoryUpdate() {
        pendingAccessoryUpdate?.cancel()
        pendingAccessoryUpdate = nil
    }

    @objc private func scheduleAccessoryUpdate() {
        guard pendingAccessoryUpdate == nil else { return }
        pendingAccessoryUpdate = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            pendingAccessoryUpdate = nil
            applyAccessory()
        }
    }

    private func applyAccessory() {
        updateAccessory(visible: accessoryVisible)
    }

    func updateAccessory(visible: Bool) {
        accessoryVisible = visible
        let isEmpty = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isEmpty || !visible { setPrivateKeyVisible(false) }
        updateVisibilityButton()
        let accessory = isEmpty ? pasteControl : visibilityButton
        if rightView !== accessory { rightView = accessory }
        rightViewMode = visible ? .always : .never
    }

    override func rightViewRect(forBounds bounds: CGRect) -> CGRect {
        CGRect(x: bounds.maxX - 44, y: bounds.midY - 22, width: 44, height: 44)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { hidePrivateKey() }
    }

    @objc private func togglePrivateKeyVisibility() {
        guard !(text ?? "").isEmpty else { return }
        setPrivateKeyVisible(isSecureTextEntry)
    }

    @objc private func hidePrivateKey() {
        setPrivateKeyVisible(false)
    }

    private func setPrivateKeyVisible(_ visible: Bool) {
        guard isSecureTextEntry == visible else { return }
        let value = text
        let selection = selectedTextRange.map {
            (offset(from: beginningOfDocument, to: $0.start), offset(from: beginningOfDocument, to: $0.end))
        }
        isSecureTextEntry = !visible
        // Reapply the value so changing secure-entry mode does not clear it on the next keystroke.
        text = value
        if let selection,
           let start = position(from: beginningOfDocument, offset: selection.0),
           let end = position(from: beginningOfDocument, offset: selection.1) {
            selectedTextRange = textRange(from: start, to: end)
        }
        updateVisibilityButton()
    }

    private func updateVisibilityButton() {
        visibilityButton.setImage(UIImage(systemName: isSecureTextEntry ? "eye" : "eye.slash"), for: .normal)
        visibilityButton.accessibilityLabel = isSecureTextEntry
            ? L10n.string("Show private key") : L10n.string("Hide private key")
    }

    override func paste(_ sender: Any?) {
        pendingPasteToken = SensitiveClipboard.capture()
        defer { pendingPasteToken = nil }
        super.paste(sender)
    }

    override func paste(itemProviders: [NSItemProvider]) {
        pendingPasteToken = SensitiveClipboard.capture()
        defer { pendingPasteToken = nil }
        becomeFirstResponder()
        super.paste(itemProviders: itemProviders)
    }

    func textPasteConfigurationSupporting(
        _ textPasteConfigurationSupporting: any UITextPasteConfigurationSupporting,
        transform item: any UITextPasteItem
    ) {
        // Carry the generation with this paste, even if another paste finishes first.
        let token = pendingPasteToken
        item.itemProvider.loadObject(ofClass: NSString.self) { object, _ in
            Task { @MainActor in
                guard let string = object as? String else {
                    item.setNoResult()
                    return
                }
                var attributes = item.defaultAttributes
                if let token { attributes[Self.pasteTokenAttribute] = token }
                item.setResult(attributedString: NSAttributedString(string: string, attributes: attributes))
            }
        }
    }

    func textPasteConfigurationSupporting(
        _ textPasteConfigurationSupporting: any UITextPasteConfigurationSupporting,
        performPasteOf attributedString: NSAttributedString,
        to textRange: UITextRange
    ) -> UITextRange {
        let priorText = text ?? ""
        let replacesWholeField = offset(from: beginningOfDocument, to: textRange.start) == 0
            && offset(from: textRange.start, to: textRange.end) == (priorText as NSString).length
        var token = attributedString.length > 0
            ? attributedString.attribute(Self.pasteTokenAttribute, at: 0, effectiveRange: nil) as? SensitiveClipboard.Token
            : nil
        attributedString.enumerateAttribute(Self.pasteTokenAttribute,
                                            in: NSRange(location: 0, length: attributedString.length)) { value, _, _ in
            if value as? SensitiveClipboard.Token != token { token = nil }
        }
        replace(textRange, withText: attributedString.string)
        sendActions(for: .editingChanged)
        onPaste?(replacesWholeField ? token : nil, text ?? "")
        return selectedTextRange ?? textRange
    }
}
