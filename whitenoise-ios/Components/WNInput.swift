import SwiftUI

nonisolated enum WNInputKind: Equatable {
    case text
    case secure
    /// Grows vertically within the given line range.
    case multiline(ClosedRange<Int>)
}

/// Visual tokens shared by every rounded text input in the app.
nonisolated enum WNInputMetrics {
    /// Single-line fields are capsules; multi-line fields keep a continuous
    /// radius that reads as the same family at the collapsed height.
    enum Shape: Equatable {
        case capsule
        case rounded(CGFloat)
    }

    static let height: CGFloat = 50
    static let accessoryTarget: CGFloat = 44
    static let contentSpacing: CGFloat = 10
    static let leadingInset: CGFloat = 16
    static let trailingInset: CGFloat = 6
    static let multilineVerticalInset: CGFloat = 12
    static let rowVerticalInset: CGFloat = 4

    static var fill: Color { Color(.secondarySystemFill) }

    /// A field inside a grouped `Form` reads as the row it replaced, so it
    /// takes the row's own background rather than the translucent fill that
    /// suits a field standing on a plain screen.
    static var groupedFill: Color { Color(.secondarySystemGroupedBackground) }

    /// A multi-line field keeps the corner a capsule has at the collapsed
    /// height, so at one line it is a pill and taller states stay in the same
    /// family. Growing the radius with the box instead would push the curve
    /// under the first line of text.
    static var multilineCornerRadius: CGFloat { height / 2 }

    static func shape(for kind: WNInputKind) -> Shape {
        switch kind {
        case .text, .secure:
            return .capsule
        case .multiline:
            return .rounded(multilineCornerRadius)
        }
    }

    /// Multi-line fields size to their content; single-line fields hold the
    /// capsule height so short and long fields line up.
    static func fixesHeight(for kind: WNInputKind) -> Bool {
        shape(for: kind) == .capsule
    }

    static func verticalInset(for kind: WNInputKind) -> CGFloat {
        fixesHeight(for: kind) ? 0 : multilineVerticalInset
    }
}

extension WNInputMetrics.Shape {
    var insettableShape: AnyShape {
        switch self {
        case .capsule:
            return AnyShape(Capsule())
        case .rounded(let radius):
            return AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }
}

extension View {
    /// Hosts a `WNInput` in a grouped `Form`. The row gives up its own
    /// background, separator and content insets so the input's capsule is the
    /// only chrome and spans the full section width.
    func wnInputRow() -> some View {
        listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(
                EdgeInsets(
                    top: WNInputMetrics.rowVerticalInset,
                    leading: 0,
                    bottom: WNInputMetrics.rowVerticalInset,
                    trailing: 0
                )
            )
    }
}

/// The app's text input: a rounded filled field with an optional leading icon,
/// a built-in clear button and a trailing accessory slot.
struct WNInput<Trailing: View>: View {
    let placeholder: String
    @Binding var text: String
    var kind = WNInputKind.text
    var icon: String?
    var fill = WNInputMetrics.fill
    var submitLabel = SubmitLabel.return
    var autocapitalization = TextInputAutocapitalization.never
    var disablesAutocorrection = true
    var showsClear = false
    var clearLabel = L10n.string("Clear")
    var focus: FocusState<Bool>.Binding?
    var onSubmit: (() -> Void)?
    @ViewBuilder let trailing: () -> Trailing

    @FocusState private var localFocus: Bool

    @ScaledMetric(relativeTo: .body) private var height = WNInputMetrics.height

    private var activeFocus: FocusState<Bool>.Binding { focus ?? $localFocus }

    var body: some View {
        let shape = WNInputMetrics.shape(for: kind).insettableShape

        return HStack(spacing: WNInputMetrics.contentSpacing) {
            if let icon {
                Image(systemName: icon)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            WNInputTextEntry(
                placeholder: placeholder,
                text: $text,
                kind: kind,
                submitLabel: submitLabel,
                autocapitalization: autocapitalization,
                disablesAutocorrection: disablesAutocorrection,
                focus: activeFocus,
                onSubmit: onSubmit
            )

            if showsClear, !text.isEmpty {
                Button(clearLabel, systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(
                        width: WNInputMetrics.accessoryTarget,
                        height: WNInputMetrics.accessoryTarget
                    )
                    .transition(.opacity)
            }

            trailing()
        }
        .padding(.leading, WNInputMetrics.leadingInset)
        .padding(.trailing, WNInputMetrics.trailingInset)
        .padding(.vertical, WNInputMetrics.verticalInset(for: kind))
        .frame(minHeight: WNInputMetrics.fixesHeight(for: kind) ? height : nil)
        .background(fill, in: shape)
        .contentShape(shape)
        // Tapping the chrome, not just the glyphs, has to focus the field.
        .onTapGesture { activeFocus.wrappedValue = true }
    }
}

extension WNInput where Trailing == EmptyView {
    init(
        placeholder: String,
        text: Binding<String>,
        kind: WNInputKind = .text,
        icon: String? = nil,
        fill: Color = WNInputMetrics.fill,
        submitLabel: SubmitLabel = .return,
        autocapitalization: TextInputAutocapitalization = .never,
        disablesAutocorrection: Bool = true,
        showsClear: Bool = false,
        clearLabel: String = L10n.string("Clear"),
        focus: FocusState<Bool>.Binding? = nil,
        onSubmit: (() -> Void)? = nil
    ) {
        self.init(
            placeholder: placeholder,
            text: text,
            kind: kind,
            icon: icon,
            fill: fill,
            submitLabel: submitLabel,
            autocapitalization: autocapitalization,
            disablesAutocorrection: disablesAutocorrection,
            showsClear: showsClear,
            clearLabel: clearLabel,
            focus: focus,
            onSubmit: onSubmit,
            trailing: { EmptyView() }
        )
    }
}

/// Turns a `WNInputKind` into a field. Shared by the filled capsule and its
/// grouped-row sibling so both spell `.secure` and `.multiline` the same way.
struct WNInputTextEntry: View {
    let placeholder: String
    @Binding var text: String
    let kind: WNInputKind
    let submitLabel: SubmitLabel
    let autocapitalization: TextInputAutocapitalization
    let disablesAutocorrection: Bool
    let focus: FocusState<Bool>.Binding
    let onSubmit: (() -> Void)?
    /// A capsule standing on its own has no room to scroll a long value, so it
    /// keeps both ends readable. A grouped row leaves the system's own
    /// end-truncation alone.
    var truncatesLongValuesInMiddle = true

    var body: some View {
        field
            .textFieldStyle(.plain)
            .frame(minWidth: 0, maxWidth: .infinity)
            .submitLabel(submitLabel)
            .textInputAutocapitalization(autocapitalization)
            .autocorrectionDisabled(disablesAutocorrection)
            .focused(focus)
            .onSubmit { onSubmit?() }
    }

    @ViewBuilder
    private var field: some View {
        switch kind {
        case .text:
            TextField(placeholder, text: $text)
                .modifier(WNInputSingleLine(isActive: truncatesLongValuesInMiddle))
        case .secure:
            SecureField(placeholder, text: $text)
                .modifier(WNInputSingleLine(isActive: truncatesLongValuesInMiddle))
        case .multiline(let lineLimit):
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(lineLimit)
        }
    }
}

/// Long pasted identifiers and URLs stay readable at both ends rather than
/// running off the trailing edge.
private struct WNInputSingleLine: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .lineLimit(1)
            .truncationMode(isActive ? .middle : .tail)
    }
}

#Preview("WNInput — Light") {
    @Previewable @State var search = ""
    @Previewable @State var key = "nsec1qqqq"
    @Previewable @State var caption = ""

    VStack(spacing: 16) {
        WNInput(
            placeholder: "Search people",
            text: $search,
            icon: "magnifyingglass",
            submitLabel: .search,
            showsClear: true
        )

        WNInput(placeholder: "Enter private key", text: $key, kind: .secure, showsClear: true)

        WNInput(
            placeholder: "Add a caption…",
            text: $caption,
            kind: .multiline(1 ... 4),
            autocapitalization: .sentences,
            disablesAutocorrection: false
        )
    }
    .padding()
}

#Preview("WNInput — Dark") {
    @Previewable @State var search = "npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"

    VStack(spacing: 16) {
        WNInput(
            placeholder: "Search people",
            text: $search,
            icon: "magnifyingglass",
            showsClear: true
        )
    }
    .padding()
    .preferredColorScheme(.dark)
}
