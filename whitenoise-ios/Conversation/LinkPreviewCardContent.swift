import SwiftUI

struct LinkPreviewCardContent: View {
    static let imageAspectRatio: CGFloat = 1.91

    let title: String?
    let host: String?
    let image: UIImage?
    let showsImageSlot: Bool
    let isFromMe: Bool

    static func host(for url: URL) -> String? {
        guard let host = url.host(percentEncoded: false) else { return nil }
        let display = host.lowercased().hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return ContentSanitizer.compactSingleLine(display, maxLength: 64)
    }

    private var cardBackground: Color {
        MessageBubblePalette.foreground(isFromMe: isFromMe).opacity(
            isFromMe ? MessageBubbleReplyLayout.sentCardOpacity : MessageBubbleReplyLayout.receivedCardOpacity
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsImageSlot {
                Color.clear
                    .aspectRatio(Self.imageAspectRatio, contentMode: .fit)
                    .overlay {
                        if let image {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                        }
                    }
                    .clipped()
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(verbatim: title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MessageBubblePalette.foreground(isFromMe: isFromMe))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                if let host {
                    Text(verbatim: host)
                        .font(.caption)
                        .foregroundStyle(MessageBubblePalette.secondaryForeground(isFromMe: isFromMe))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, MessageBubbleReplyLayout.cardHorizontalInset)
            .padding(.vertical, MessageBubbleReplyLayout.cardVerticalInset + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(cardBackground)
        .clipShape(.rect(cornerRadius: MessageBubbleReplyLayout.cardCornerRadius, style: .continuous))
        .contentShape(.rect(cornerRadius: MessageBubbleReplyLayout.cardCornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isLink)
    }
}

#Preview {
    LinkPreviewCardContent(
        title: "An example article title that runs long enough to wrap onto a second line",
        host: "example.com",
        image: nil,
        showsImageSlot: true,
        isFromMe: false
    )
    .frame(width: MessageBubbleReplyLayout.richContentWidth)
    .padding()
}
