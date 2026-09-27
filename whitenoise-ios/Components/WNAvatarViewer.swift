import SwiftUI

struct WNAvatarViewer<Avatar: View>: View {
    @Environment(\.dismiss) private var dismiss
    @ViewBuilder let avatar: (CGFloat) -> Avatar

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let diameter = max(0, side - 32)
            WNZoomableContent(naturalSize: CGSize(width: side, height: side),
                              accessibilityLabel: L10n.string("Photo")) {
                avatar(diameter)
                    .frame(width: diameter, height: diameter)
                    .clipShape(.circle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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
