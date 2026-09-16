import SwiftUI

struct BlockedConversationNotice: View {
    let npub: String

    var body: some View {
        VStack(spacing: 4) {
            Text("You blocked this user. Unblock them to send messages.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            NavigationLink {
                ProfileContentView(npub: npub).wnBackButton()
            } label: {
                Text("View Profile")
                    .font(.footnote.weight(.semibold))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }
}
