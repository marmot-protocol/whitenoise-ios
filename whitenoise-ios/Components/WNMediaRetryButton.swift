import SwiftUI

struct WNMediaRetryButton: View {
    let action: () -> Void

    var body: some View {
        Button("Retry", systemImage: "arrow.clockwise", action: action)
            .font(.headline)
            .wnSecondaryButtonStyle()
            .controlSize(.large)
    }
}

#Preview("WNMediaRetryButton — Light") {
    WNMediaRetryButton {}
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { WNMediaSurface() }
}

#Preview("WNMediaRetryButton — Dark") {
    WNMediaRetryButton {}
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { WNMediaSurface() }
        .preferredColorScheme(.dark)
}
