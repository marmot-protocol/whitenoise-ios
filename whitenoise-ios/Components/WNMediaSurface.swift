import SwiftUI

/// Letterboxing around a photo is chrome, not content, so it follows the
/// appearance instead of pinning every media screen to black.
struct WNMediaSurface: View {
    var body: some View {
        Color(.systemBackground)
    }
}

#Preview("WNMediaSurface — Light") {
    WNMediaSurface()
        .overlay { Image(systemName: "photo").font(.largeTitle) }
}

#Preview("WNMediaSurface — Dark") {
    WNMediaSurface()
        .overlay { Image(systemName: "photo").font(.largeTitle) }
        .preferredColorScheme(.dark)
}
