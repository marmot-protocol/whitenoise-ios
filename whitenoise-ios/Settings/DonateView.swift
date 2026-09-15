import SwiftUI

struct DonateView: View {
    @Environment(\.openURL) private var openURL

    private let donationURL = URL(
        string: "https://ipf.dev/donate/?utm_source=whitenoise_ios&utm_medium=app&utm_campaign=donations"
    )!

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "heart")
                        .font(.largeTitle)
                        .foregroundStyle(.primary)
                    Text("Support White Noise")
                        .font(.headline)
                    Text("White Noise is free and open source. Donations help us improve it and keep it available to everyone.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            Section {
                WNButton(title: "Donate") {
                    openURL(donationURL)
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
        .localizedNavigationTitle("Donate")
        .navigationBarTitleDisplayMode(.inline)
    }
}
