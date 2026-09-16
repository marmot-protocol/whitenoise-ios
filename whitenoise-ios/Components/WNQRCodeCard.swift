import SwiftUI
import UIKit

struct WNQRCodeCard: View {
    nonisolated enum Metrics {
        static let widthFraction: CGFloat = 0.81
        static let cornerRadius: CGFloat = 16
        static let quietZonePadding: CGFloat = 12

        static func width(forContainerWidth containerWidth: CGFloat) -> CGFloat {
            containerWidth * widthFraction
        }
    }

    let image: UIImage?
    let accessibilityLabel: LocalizedStringKey

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
            } else {
                ProgressView()
                    .tint(.black)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(Metrics.quietZonePadding)
        .containerRelativeFrame(.horizontal) { length, _ in
            Metrics.width(forContainerWidth: length)
        }
        .aspectRatio(1, contentMode: .fit)
        .background(.white, in: .rect(cornerRadius: Metrics.cornerRadius, style: .continuous))
        .accessibilityLabel(accessibilityLabel)
    }
}

#Preview("WNQRCodeCard") {
    Form {
        Section {
            WNQRCodeCard(
                image: QRCode.image(from: "marmot://profile/npub1example", removesQuietZone: true),
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
