import SwiftUI

/// Shared form presentation; the owning flow retains draft, upload and save behavior.
enum WNProfileField: Hashable {
    case name, address, about
}

struct WNProfileNameSection: View {
    @Binding var text: String
    let focus: FocusState<WNProfileField?>.Binding
    var isEditing = true
    var nextField: WNProfileField = .about
    var onHeightChange: ((CGFloat) -> Void)?

    var body: some View {
        Section("Name") {
            Group {
                if isEditing {
                    TextField("Name", text: $text)
                        .textContentType(.name)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.next)
                        .focused(focus, equals: .name)
                        .onSubmit { focus.wrappedValue = nextField }
                } else {
                    Text(text.isEmpty ? L10n.string("Name") : text)
                        .foregroundStyle(text.isEmpty ? .secondary : .primary)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeightChange?($0) }
            .id(WNProfileField.name)
            .listRowBackground(Color(uiColor: .secondarySystemFill))
        }
    }
}

struct WNProfileAboutSection: View {
    @Binding var text: String
    let focus: FocusState<WNProfileField?>.Binding
    var isEditing = true
    var onHeightChange: ((CGFloat) -> Void)?

    var body: some View {
        Section("About") {
            Group {
                if isEditing {
                    TextField("A little about you", text: $text, axis: .vertical)
                        .lineLimit(3 ... 6)
                        .textInputAutocapitalization(.sentences)
                        .focused(focus, equals: .about)
                        .accessibilityLabel("About")
                } else {
                    Text(text.isEmpty ? L10n.string("A little about you") : text)
                        .foregroundStyle(text.isEmpty ? .secondary : .primary)
                        .lineLimit(3...)
                        .accessibilityLabel("About")
                        .accessibilityValue(text.isEmpty ? L10n.string("A little about you") : text)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeightChange?($0) }
            .id(WNProfileField.about)
            .listRowBackground(Color(uiColor: .secondarySystemFill))
        }
    }
}

struct WNProfilePhotoSection<Avatar: View>: View {
    let hasPhoto: Bool
    @Binding var selection: WNPhotoMenuAction?
    var isEditing = true
    var isBusy = false
    var isDisabled = false
    var error: String?
    @ViewBuilder var avatar: () -> Avatar

    var body: some View {
        Section {
            Group {
                if isEditing {
                    WNAvatarPhotoMenu(
                        hasPhoto: hasPhoto, selection: $selection,
                        buttonControlSize: .regular, isLoading: isBusy,
                        preview: avatar
                    )
                    .disabled(isBusy || isDisabled)
                } else {
                    avatar()
                        .containerRelativeFrame(.horizontal, count: 3, span: 1, spacing: 0)
                }
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } footer: {
            if isEditing, let error {
                Text(error).foregroundStyle(.red)
            }
        }
    }
}

struct WNProfilePrivacySection: View {
    let onLearnMore: () -> Void

    var body: some View {
        Section {
            WNProfilePrivacyNote(onLearnMore: onLearnMore)
                .padding(.vertical, 4)
                .listRowBackground(Color(uiColor: .quaternarySystemFill))
        }
    }
}
