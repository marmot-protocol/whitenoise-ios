import SwiftUI

struct WNAvatarViewer<Avatar: View>: View {
    @Environment(\.dismiss) private var dismiss
    @ViewBuilder let avatar: (CGFloat) -> Avatar

    var body: some View {
        GeometryReader { geometry in
            let diameter = max(0, min(geometry.size.width, geometry.size.height) - 32)
            avatar(diameter)
                .frame(width: diameter, height: diameter)
                .clipShape(.circle)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.string("Photo"))
                .accessibilityAddTraits(.isImage)
        }
        .overlay(alignment: .topLeading) {
            WNIconButton(title: "Close", systemImage: "xmark") { dismiss() }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .background { WNMediaSurface().ignoresSafeArea() }
    }
}

extension View {
    func wnAvatarViewer<Avatar: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder avatar: @escaping (CGFloat) -> Avatar
    ) -> some View {
        fullScreenCover(isPresented: isPresented) {
            WNAvatarViewer(avatar: avatar)
                .appAppearance()
        }
    }
}

#Preview("WNAvatarViewer") {
    WNAvatarViewer { size in
        AvatarBubble(seed: "Marmota", title: "Marmota")
            .frame(width: size, height: size)
    }
}
