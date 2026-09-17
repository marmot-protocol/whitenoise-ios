import SwiftUI
import UIKit

struct WNQRCodeCard: View {
    nonisolated enum Metrics {
        static let widthFraction: CGFloat = 0.906
        static let cornerRadius: CGFloat = 16

        static func width(forContainerWidth containerWidth: CGFloat) -> CGFloat {
            containerWidth * widthFraction
        }
    }

    let image: UIImage?
    let accessibilityLabel: LocalizedStringKey

    var body: some View {
        content
            .containerRelativeFrame(.horizontal) { length, _ in
                Metrics.width(forContainerWidth: length)
            }
            .aspectRatio(1, contentMode: .fit)
            .background(.white)
            .clipShape(.rect(cornerRadius: Metrics.cornerRadius, style: .continuous))
            .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
        } else {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    ProgressView()
                        .tint(.black)
                }
        }
    }
}

#Preview("WNQRCodeCard") {
    Form {
        Section {
            WNQRCodeCard(
                image: QRCode.image(from: "marmot://profile/npub1example"),
                accessibilityLabel: "Profile QR code"
            )
            .frame(maxWidth: .infinity)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())

        Section {
            WNQRCodeCard(image: nil, accessibilityLabel: "Profile QR code")
                .frame(maxWidth: .infinity)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }
}
