import SwiftUI

struct GroupInfoFormSections<Preview: View, Footer: View>: View {
    @Binding var name: String
    @Binding var description: String
    let namePlaceholder: String
    let hasPhoto: Bool
    @Binding var photoMenuAction: WNPhotoMenuAction?
    var photoProgressLabel: String?
    var isDisabled = false
    @ViewBuilder var preview: () -> Preview
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        Section {
            VStack(spacing: 0) {
                WNAvatarPhotoMenu(hasPhoto: hasPhoto, selection: $photoMenuAction, preview: preview)
                    .disabled(isDisabled)

                if let photoProgressLabel {
                    ProgressView(photoProgressLabel)
                        .font(.footnote)
                        .padding(.top)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)

        Section {
            TextField(namePlaceholder, text: $name)
                .textContentType(.organizationName)
                .textInputAutocapitalization(.words)
                .disabled(isDisabled)

            TextField(L10n.string("Description"), text: $description, axis: .vertical)
                .lineLimit(2...5)
                .disabled(isDisabled)
        } header: {
            Text("Group Details")
        } footer: {
            footer()
        }
    }
}

#Preview("GroupInfoFormSections") {
    @Previewable @State var name = "Weekend Walks"
    @Previewable @State var description = ""
    @Previewable @State var action: WNPhotoMenuAction?

    Form {
        GroupInfoFormSections(
            name: $name,
            description: $description,
            namePlaceholder: "Group name",
            hasPhoto: false,
            photoMenuAction: $action
        ) {
            WNAvatarPreview(name: name, emptySystemImage: "person.2")
        } footer: {
            Text("Everyone in the group will see this name and description.")
        }
    }
}
