import SwiftUI

struct ChatInviteBadge: View {
    var body: some View {
        WNBadge(symbol: ChatRowStatusPresentation.invitationSymbolName)
            .accessibilityLabel(L10n.string("Chat invitation"))
    }
}

#Preview("ChatInviteBadge — Light") {
    ChatInviteBadge()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
}

#Preview("ChatInviteBadge — Dark") {
    ChatInviteBadge()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .preferredColorScheme(.dark)
}
