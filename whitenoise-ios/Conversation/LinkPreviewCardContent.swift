import SwiftUI

struct LinkPreviewCardContent: View {
    static let imageAspectRatio: CGFloat = 256.0 / 124.0

    let title: String?
    var summary: String? = nil
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
            VStack(alignment: .leading, spacing: 4) {
                if let host {
                    Label {
                        TimelineSearchText(host, keepsMatchVisible: true)
                    } icon: { Image(systemName: "link") }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(MessageBubblePalette.secondaryForeground(isFromMe: isFromMe))
                    .lineLimit(1)
                }
                if let title {
                    TimelineSearchText(title, keepsMatchVisible: true)
                        .font(.headline)
                        .lineLimit(2)
                }
                if let summary {
                    TimelineSearchText(summary, keepsMatchVisible: true)
                        .font(.subheadline)
                        .lineLimit(3)
                        .opacity(0.78)
                }
            }
            .foregroundStyle(MessageBubblePalette.foreground(isFromMe: isFromMe))
            .multilineTextAlignment(.leading)
            .padding(MessageBubbleReplyLayout.cardOuterInset)
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
