import SwiftUI

/// A fixed-size export, independent of the device's appearance and text-size settings.
struct ProfileShareCard: View {
    let accountIdHex: String
    let displayName: String
    let avatar: UIImage?
    let qrImage: UIImage

    var body: some View {
        VStack(spacing: 0) {
            Text("On White Noise? Message me here.")
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(Color(white: 0.4))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .frame(height: 46)
                .padding(.horizontal, 32)
                .padding(.top, 12)

            HStack(spacing: 12) {
                AvatarBubble(seed: accountIdHex, title: displayName, pictureImage: avatar)
                    .frame(width: 44, height: 44)

                Text(verbatim: displayName)
                    .font(.system(size: 28, weight: .bold))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .minimumScaleFactor(0.65)
            }
            .frame(height: 60)
            .padding(.horizontal, 32)
            .padding(.top, 4)
            .padding(.bottom, 8)

            Image(uiImage: qrImage)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .frame(width: 300, height: 300)
                .padding(12)
                .background(.white, in: RoundedRectangle(cornerRadius: 24))

            Spacer(minLength: 8)
            Image("WnLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
                .padding(.bottom, 2)
            Text(verbatim: "whitenoise.chat")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .padding(.bottom, 12)
        }
        .frame(width: 480, height: 540)
        .foregroundStyle(.black)
        .background(Color(white: 0.96))
        .environment(\.colorScheme, .light)
        .environment(\.dynamicTypeSize, .large)
    }

    @MainActor
    static func render(accountIdHex: String, displayName: String, avatar: UIImage?, profileURL: String) throws -> UIImage {
        guard let qrImage = QRCode.image(from: profileURL) else { throw RenderError.unavailable }
        let renderer = ImageRenderer(content: ProfileShareCard(
            accountIdHex: accountIdHex, displayName: displayName, avatar: avatar, qrImage: qrImage
        )
        // ImageRenderer starts a separate view tree without the app's locale environment.
        .environment(\.locale, AppLanguage.currentLocale))
        renderer.scale = 3
        renderer.isOpaque = true
        guard let image = renderer.uiImage else { throw RenderError.unavailable }
        return image
    }

    private enum RenderError: Error {
        case unavailable
    }
}
