import SwiftUI
import UIKit
import MarmotKit

/// Import an existing local-signing Nostr identity. `npub...` is only a public
/// identity and is intentionally not accepted as a sign-in credential.
struct ImportIdentityView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var model = ImportIdentityViewModel()

    private var canSubmit: Bool {
        !model.isImporting && Self.isPlausibleNsec(model.identity)
    }

    /// A bech32 `nsec` is a fixed-width encoding of a 32-byte key: the `nsec1`
    /// human-readable prefix plus 58 data/checksum characters, 63 in total.
    /// Gating on `hasPrefix("nsec")` alone enabled Import for incomplete input
    /// like `nsec` or `nsecfoo` (issue #40); require the full canonical shape so
    /// the button only enables once a complete key has been entered.
    static func isPlausibleNsec(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("nsec1") && trimmed.count == 63
    }

    static func consumeIdentityForImport(_ raw: inout String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        raw = ""
        return trimmed
    }

    var body: some View {
        @Bindable var model = model
        return Form {
            Section {
                PasteAwareNsecField(
                    text: $model.identity,
                    placeholder: "nsec1…",
                    onPaste: { token, resultingIdentity in
                        // Capture the clipboard generation at the moment of a
                        // genuine user paste, then tie it to the post-paste
                        // field value so later edits cannot clear stale data.
                        model.recordPastedClipboardToken(token, resultingIdentity: resultingIdentity)
                    }
                )
                .privacySensitive()
            } header: {
                Text("Identity")
            } footer: {
                Text("Paste your nsec (bech32 secret key). Public npub values are for sharing and cannot sign in.")
                    .font(.footnote)
            }

            Section {
                Button {
                    Task { await model.runImport(using: appState, dismiss: { dismiss() }) }
                } label: {
                    HStack {
                        if model.isImporting {
                            ProgressView().controlSize(.small)
                        }
                        Text(model.isImporting ? L10n.string("Importing…") : L10n.string("Import"))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 2)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canSubmit)
            }

            if let error = model.error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
        }
        .navigationTitle("Import Identity")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(model.isImporting)
        .onDisappear {
            model.identity = ""
        }
    }
}

/// Multi-line nsec entry field backed by a `UITextView` so we can intercept
/// genuine user paste events. SwiftUI's `TextField` gives no paste hook, and we
/// must capture the pasteboard generation only when the user actually pastes —
/// not on every keystroke/autofill — so a later clipboard wipe can prove it
/// still owns the pasted secret without reading `.string` (#409).
private struct PasteAwareNsecField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onPaste: (SensitiveClipboard.Token, String) -> Void

    /// Roughly three lines tall so it matches the old `lineLimit(3...6)` field.
    private static let minimumLineCount: CGFloat = 3

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> PasteInterceptingTextView {
        let textView = PasteInterceptingTextView()
        textView.onPaste = onPaste
        textView.delegate = context.coordinator
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.font = UIFontMetrics(forTextStyle: .body)
            .scaledFont(for: .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular))
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.smartInsertDeleteType = .no
        textView.textContentType = .none
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let placeholderLabel = UILabel()
        placeholderLabel.text = placeholder
        placeholderLabel.font = textView.font
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.numberOfLines = 0
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        textView.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor),
            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: textView.trailingAnchor)
        ])
        context.coordinator.placeholderLabel = placeholderLabel

        // Keep at least ~3 lines of height like the old field's minimum.
        let lineHeight = textView.font?.lineHeight ?? UIFont.preferredFont(forTextStyle: .body).lineHeight
        textView.heightAnchor
            .constraint(greaterThanOrEqualToConstant: lineHeight * Self.minimumLineCount)
            .isActive = true

        textView.text = text
        placeholderLabel.isHidden = !text.isEmpty
        return textView
    }

    func updateUIView(_ uiView: PasteInterceptingTextView, context: Context) {
        uiView.onPaste = onPaste
        if uiView.text != text {
            uiView.text = text
        }
        context.coordinator.placeholderLabel?.isHidden = !uiView.text.isEmpty
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding private var text: String
        weak var placeholderLabel: UILabel?

        init(text: Binding<String>) {
            _text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            text = textView.text
            placeholderLabel?.isHidden = !textView.text.isEmpty
        }
    }
}

/// `UITextView` subclass that snapshots the clipboard generation on a genuine
/// user paste. `paste(_:)` fires ONLY for user-initiated paste (⌘V,
/// context-menu Paste, the paste button) — never for typing, autofill,
/// dictation, or drag-and-drop — so this is the trustworthy signal for the
/// `SensitiveClipboard` clear gate.
private final class PasteInterceptingTextView: UITextView {
    var onPaste: ((SensitiveClipboard.Token, String) -> Void)?

    override func paste(_ sender: Any?) {
        // Snapshot the generation BEFORE the paste mutates anything; capture
        // reads only changeCount metadata (no `.string`, no banner).
        let token = SensitiveClipboard.capture()
        super.paste(sender)
        onPaste?(token, text ?? "")
    }
}
