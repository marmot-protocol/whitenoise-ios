import SwiftUI

/// Composer replacement for a direct chat with a blocked peer. It states why
/// sending is unavailable and offers the undo inline, so unblocking doesn't
/// require walking back out to the profile.
struct BlockedConversationNotice: View {
    let npub: String
    var canUnblock: Bool
    var isUnblocking: Bool
    var onUnblock: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Label {
                Text("You blocked this user. Unblock them to send messages.")
            } icon: {
                Image(systemName: "hand.raised")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)

            HStack(spacing: 12) {
                WNButtonNavigationLink(
                    title: "View Profile",
                    emphasis: .secondary,
                    size: .standard
                ) {
                    ProfileContentView(npub: npub).wnBackButton()
                }

                WNButton(
                    title: "Unblock",
                    systemImage: "person.crop.circle.badge.checkmark",
                    size: .standard,
                    isLoading: isUnblocking
                ) {
                    onUnblock()
                }
                .disabled(!canUnblock)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }
}

/// Re-applies the timeline's author filter when the live block list changes or
/// when the view model finishes loading, whichever lands second.
struct BlockedAuthorsToken: Equatable {
    let accountIdHexes: Set<String>
    let isViewModelReady: Bool
}
