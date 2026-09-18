import SwiftUI

struct ProfileContactActions: View {
    let contactName: String
    var isMessaging = false
    let onMessage: () -> Void
    let onNewGroup: () -> Void
    let onAddToGroup: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            DetailsActionButton(title: "Message", systemImage: "message",
                                isLoading: isMessaging, action: onMessage)
            DetailsActionButton(title: "New Group", systemImage: "person.2.badge.plus", action: onNewGroup)
                .accessibilityLabel(L10n.formatted("Create group with %@", contactName))
            DetailsActionButton(title: "Add to Group", systemImage: "person.badge.plus", action: onAddToGroup)
        }
        .tint(.primary)
    }
}
