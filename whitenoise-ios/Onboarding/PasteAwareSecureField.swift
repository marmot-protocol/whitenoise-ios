import SwiftUI
import UIKit

struct PasteAwareSecureField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let showsAccessory: Bool
    let onClear: () -> Void
    let onPaste: (SensitiveClipboard.Token?, String) -> Void
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            isFocused: $isFocused,
            onSubmit: onSubmit
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
        field.textContentType = nil
        field.returnKeyType = .go
        field.adjustsFontForContentSizeCategory = true
        field.font = UIFont.preferredFont(forTextStyle: .body)
        field.addTarget(
            context.coordinator,
            action: #selector(Coordinator.textChanged(_:)),
            for: .editingChanged
        )
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
        field.onPaste = onPaste
        if field.text != text {
            field.text = text
        }
        if isFocused, !field.isFirstResponder {
            field.becomeFirstResponder()
        } else if !isFocused, field.isFirstResponder {
            field.resignFirstResponder()
        }
        field.onClear = onClear
        field.updateAccessory(visible: showsAccessory)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        @Binding private var text: String
        @Binding private var isFocused: Bool
        let onSubmit: () -> Void

        init(
            text: Binding<String>,
            isFocused: Binding<Bool>,
            onSubmit: @escaping () -> Void
        ) {
            _text = text
            _isFocused = isFocused
            self.onSubmit = onSubmit
        }

        @objc func textChanged(_ field: UITextField) {
            text = field.text ?? ""
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            isFocused = true
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            isFocused = false
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            onSubmit()
            return true
        }
    }
}

final class PasteInterceptingSecureTextField: UITextField, UITextPasteDelegate {
    var onPaste: ((SensitiveClipboard.Token?, String) -> Void)?
    var onClear: (() -> Void)?
    private var pendingPasteToken: SensitiveClipboard.Token?
    private static let pasteTokenAttribute = NSAttributedString.Key("WhiteNoisePasteToken")
    private var pasteControl: UIPasteControl?
    private let clearButton = UIButton(type: .system)

    func configureAccessory() {
        rebuildPasteControl()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitUserInterfaceLevel.self]) {
            (field: PasteInterceptingSecureTextField, _: UITraitCollection) in
            field.rebuildPasteControl()
        }
        clearButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        clearButton.tintColor = .label
        clearButton.accessibilityLabel = L10n.string("Clear")
        clearButton.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        clearButton.addTarget(self, action: #selector(clearInput), for: .touchUpInside)
        updateAccessory(visible: true)
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
        updateAccessory(visible: rightViewMode != .never)
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

    func updateAccessory(visible: Bool) {
        let accessory = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? pasteControl : clearButton
        if rightView !== accessory { rightView = accessory }
        rightViewMode = visible ? .always : .never
    }

    override func rightViewRect(forBounds bounds: CGRect) -> CGRect {
        CGRect(x: bounds.maxX - 44, y: bounds.midY - 22, width: 44, height: 44)
    }

    @objc private func clearInput() {
        text = ""
        pendingPasteToken = nil
        sendActions(for: .editingChanged)
        onClear?()
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
