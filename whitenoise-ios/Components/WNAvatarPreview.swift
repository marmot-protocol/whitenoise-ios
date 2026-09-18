import SwiftUI
import UIKit

/// The large editable avatar shared by Sign Up and Profile: a circle filled
/// with the monochrome accent, showing the profile photo when there is one and
/// a single monogram letter otherwise. Row-sized avatars use `AvatarBubble`,
/// whose two-letter monogram is sized for a list row rather than a header.
struct WNAvatarPreview: View {
    @Environment(\.colorScheme) private var colorScheme

    let name: String
    var image: UIImage?
    var pictureURL: URL?
    var emptySystemImage: String?

    private var showsEmptySymbol: Bool {
        image == nil && pictureURL == nil && emptySystemImage != nil
            && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Circle()
                    .fill(showsEmptySymbol
                          ? Color(uiColor: .secondarySystemFill)
                          : WNButton.Metrics.accent(for: colorScheme))

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    if showsEmptySymbol, let emptySystemImage {
                        Image(systemName: emptySystemImage)
                            .font(.largeTitle)
                            .foregroundStyle(.primary)
                    } else {
                        Text(WNAvatarMonogram.initial(for: name))
                            .font(.largeTitle.weight(.semibold))
                            .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                    }

                    // Painted over the monogram, so a slow remote avatar shows
                    // the letter rather than an empty circle.
                    if let pictureURL {
                        AvatarRemoteImage(url: pictureURL)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipShape(.circle)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string("Profile avatar preview"))
    }
}

nonisolated enum WNAvatarMonogram {
    /// One letter, not two: the large avatar reads as a monogram, and a second
    /// letter only appears for names that happen to have a second word.
    static func initial(for name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .first
            .map { String($0).uppercased() }
            ?? "?"
    }
}

#Preview("WNAvatarPreview — Light") {
    HStack(spacing: 24) {
        WNAvatarPreview(name: "Marmota")
            .frame(width: 131, height: 131)
        WNAvatarPreview(name: "ada lovelace")
            .frame(width: 131, height: 131)
        WNAvatarPreview(name: "")
            .frame(width: 131, height: 131)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
}

#Preview("WNAvatarPreview — Dark") {
    WNAvatarPreview(name: "Marmota")
        .frame(width: 131, height: 131)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .preferredColorScheme(.dark)
}

#Preview("WNAvatarPreview — Group setup") {
    HStack(spacing: 24) {
        WNAvatarPreview(name: "", emptySystemImage: "person.2")
        WNAvatarPreview(name: "Weekend Walks", emptySystemImage: "person.2")
    }
    .frame(height: 131)
    .padding()
}
