import SwiftUI
import UIKit

/// Uses the WN input styling, with UIKit edit validation before text changes.
struct DonationAmountInput: View {
    let text: String
    @Binding var focused: Bool
    let decideEdit: (String, NSRange, String, Bool) -> DonationAmountEdit
    let onChange: (String) -> Void
    @ScaledMetric(relativeTo: .body) private var height = WNInputMetrics.height

    var body: some View {
        HStack(spacing: WNInputMetrics.contentSpacing) {
            DonationAmountTextField(text: text, focused: $focused, decideEdit: decideEdit, onChange: onChange)
                .frame(minWidth: 0, maxWidth: .infinity)
            Text("USD")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, WNInputMetrics.leadingInset)
        .frame(minHeight: height)
        .background(WNInputMetrics.fill, in: Capsule())
        .contentShape(Capsule())
        .onTapGesture { focused = true }
    }
}

private struct DonationAmountTextField: UIViewRepresentable {
    let text: String
    @Binding var focused: Bool
    let decideEdit: (String, NSRange, String, Bool) -> DonationAmountEdit
    let onChange: (String) -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> AmountTextField {
        let field = AmountTextField()
        field.delegate = context.coordinator
        field.placeholder = L10n.string("Custom amount")
        field.accessibilityLabel = L10n.string("Custom donation amount in USD")
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.textColor = .label
        field.tintColor = .label
        field.keyboardType = .decimalPad
        field.autocorrectionType = .no
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.applyPaste = { [weak coordinator = context.coordinator] field, replacement in
            coordinator?.paste(replacement, into: field)
        }
        return field
    }

    func updateUIView(_ field: AmountTextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
        field.isEnabled = isEnabled
        if focused && !field.isFirstResponder { field.becomeFirstResponder() }
        if !focused && field.isFirstResponder { field.resignFirstResponder() }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: AmountTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: uiView.font?.lineHeight ?? WNInputMetrics.height)
    }

    final class AmountTextField: UITextField {
        var applyPaste: ((AmountTextField, String) -> Void)?

        override func paste(_ sender: Any?) {
            // Read only in response to the user's Paste action.
            guard let text = UIPasteboard.general.string else { return }
            applyPaste?(self, text)
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: DonationAmountTextField
        init(parent: DonationAmountTextField) { self.parent = parent }

        @objc func changed(_ field: UITextField) { parent.onChange(field.text ?? "") }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            if !parent.focused { parent.focused = true }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            if parent.focused { parent.focused = false }
        }

        func textField(_ field: UITextField, shouldChangeCharactersIn range: NSRange, replacementString replacement: String) -> Bool {
            switch parent.decideEdit(field.text ?? "", range, replacement, false) {
            case .accept: return true
            case .reject: return false
            }
        }

        func paste(_ replacement: String, into field: AmountTextField) {
            guard let selection = field.selectedTextRange else { return }
            let range = NSRange(
                location: field.offset(from: field.beginningOfDocument, to: selection.start),
                length: field.offset(from: selection.start, to: selection.end)
            )
            switch parent.decideEdit(field.text ?? "", range, replacement, true) {
            case let .accept(text):
                field.text = text
                let caret = min(range.location + (replacement as NSString).length, (text as NSString).length)
                if let position = field.position(from: field.beginningOfDocument, offset: caret) {
                    field.selectedTextRange = field.textRange(from: position, to: position)
                }
                parent.onChange(text)
            case .reject: break
            }
        }
    }
}
