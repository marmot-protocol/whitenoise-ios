import SwiftUI

/// The public-profile explanation shared by sign-up and editing an existing profile.
struct WNProfilePrivacyNote: View {
    var showsIcon = true
    let onLearnMore: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if showsIcon {
                Image(systemName: "eye")
                    .foregroundStyle(.primary)
                    .accessibilityHidden(true)
            }
            Text(summary)
                .fixedSize(horizontal: false, vertical: true)
                .tint(.primary)
                .environment(\.openURL, OpenURLAction { _ in
                    onLearnMore()
                    return .handled
                })
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private var summary: AttributedString {
        var summary = AttributedString(L10n.string("Your name, photo, and bio are public.\nShare only what you’re comfortable with."))
        var learnMore = AttributedString(L10n.string("Learn more"))
        learnMore.link = URL(string: "whitenoise:profile-privacy")
        learnMore.underlineStyle = .single
        summary += AttributedString("\n")
        summary += learnMore
        return summary
    }
}

struct WNProfilePrivacyDetailsView: View {
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .title) private var iconSize = 48.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "eye")
                    .font(.system(size: iconSize))
                    .foregroundStyle(.primary)
                    .accessibilityHidden(true)
                Text("Your profile is public")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("Anyone can see your name, photo, and bio, including people using other apps on the same network. You can use a nickname instead of your real name.")
                Text("Share only what you’re comfortable making public. Photos may stay online even after you remove them from your profile.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                WNIconButton(title: "Close", systemImage: "xmark") {
                    dismiss()
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
        }
        .font(.body)
        .foregroundStyle(.primary)
        .presentationBackground(Color(uiColor: .systemBackground))
    }
}
