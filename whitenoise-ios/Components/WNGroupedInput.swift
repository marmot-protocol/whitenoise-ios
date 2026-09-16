import SwiftUI

/// The app's second text field: a plain row inside a grouped `Form` section.
///
/// `WNInput` is the filled capsule a field takes when it stands alone and is
/// the point of its section — a name on sign-up, a key to paste. A form that
/// reads as one card of stacked rows, like Group Details, takes this instead:
/// the section draws the card and the rows divide it, so a capsule per row
/// would box a box. Both share `WNInputTextEntry`, so `.secure` and
/// `.multiline` behave the same either way.
struct WNGroupedInput: View {
    let placeholder: String
    @Binding var text: String
    var kind = WNInputKind.text
    /// Set only on a screen whose every section is rounded. Rounding one
    /// section while its neighbours stay system-drawn reads worse on the iOS
    /// 18 floor than leaving the whole screen to the system.
    var cardPosition: WNGroupedCardPosition?
    var submitLabel = SubmitLabel.return
    var autocapitalization = TextInputAutocapitalization.sentences
    var disablesAutocorrection = false
    var focus: FocusState<Bool>.Binding?
    var onSubmit: (() -> Void)?

    @FocusState private var localFocus: Bool

    private var activeFocus: FocusState<Bool>.Binding { focus ?? $localFocus }

    var body: some View {
        WNInputTextEntry(
            placeholder: placeholder,
            text: $text,
            kind: kind,
            submitLabel: submitLabel,
            autocapitalization: autocapitalization,
            disablesAutocorrection: disablesAutocorrection,
            focus: activeFocus,
            onSubmit: onSubmit,
            truncatesLongValuesInMiddle: false
        )
        .wnGroupedInputCard(cardPosition)
    }
}

private extension View {
    @ViewBuilder
    func wnGroupedInputCard(_ position: WNGroupedCardPosition?) -> some View {
        if let position {
            wnGroupedCardRow(position)
        } else {
            self
        }
    }
}

#Preview("WNGroupedInput — Light") {
    @Previewable @State var name = ""
    @Previewable @State var about = "Weekly sync for the release crew."

    Form {
        Section {
            WNGroupedInput(placeholder: "Group Name", text: $name, submitLabel: .next)
            WNGroupedInput(
                placeholder: "Description",
                text: $about,
                kind: .multiline(2 ... 5)
            )
        } header: {
            Text("Group Details")
        } footer: {
            Text("Everyone in the group will see this name and description.")
        }
    }
}

#Preview("WNGroupedInput — Dark") {
    @Previewable @State var name = "Release crew"
    @Previewable @State var about = ""

    Form {
        Section {
            WNGroupedInput(placeholder: "Group Name", text: $name)
            WNGroupedInput(
                placeholder: "Description",
                text: $about,
                kind: .multiline(2 ... 5)
            )
        } header: {
            Text("Group Details")
        }
    }
    .preferredColorScheme(.dark)
}
