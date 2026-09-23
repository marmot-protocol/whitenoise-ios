import SwiftUI
import UIKit

/// The large editable avatar shared by Sign Up and Profile: a circle filled
/// with the monochrome accent, showing the profile photo when there is one and
/// a single monogram letter otherwise. Initials share the same size scale as
/// the row and header avatars rendered by `AvatarBubble`.
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
                        WNAvatarMonogramView(name: name)
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

struct WNAvatarMonogramView: View {
    let name: String

    var body: some View {
        GeometryReader { geometry in
            let diameter = min(geometry.size.width, geometry.size.height)
            Text(WNAvatarMonogram.initial(for: name))
                .font(.system(size: WNAvatarMonogram.fontSize(for: diameter), weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, diameter * 0.1)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

nonisolated enum WNAvatarMonogram {
    private static let sizeScale: [(diameter: CGFloat, fontSize: CGFloat)] = [
        (0, 0),
        (32, 14),
        (44, 18),
        (56, 22),
        (72, 28),
        (104, 40),
        (126, 48)
    ]

    static func fontSize(for diameter: CGFloat) -> CGFloat {
        // Interpolate for intermediate row sizes and responsive profile headers.
        for (lower, upper) in zip(sizeScale, sizeScale.dropFirst()) where diameter <= upper.diameter {
            let fraction = max(0, diameter - lower.diameter) / (upper.diameter - lower.diameter)
            return max(1, lower.fontSize + fraction * (upper.fontSize - lower.fontSize))
        }
        return diameter * 48 / 126
    }

    /// One letter, not two: the large avatar reads as a monogram, and a second
    /// letter only appears for names that happen to have a second word.
    static func initial(for name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .first
            .map { String($0).uppercased() }
            ?? "?"
    }
}

#Preview("Avatar initials — size scale") {
    VStack(spacing: 16) {
        ForEach([32, 44, 56, 72, 104, 126], id: \.self) { diameter in
            HStack(spacing: 16) {
                ForEach(["Vladimir", "Marmota", "小明"], id: \.self) { name in
                    AvatarBubble(seed: name, title: name)
                        .frame(width: CGFloat(diameter), height: CGFloat(diameter))
                }
            }
        }
    }
    .padding()
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
