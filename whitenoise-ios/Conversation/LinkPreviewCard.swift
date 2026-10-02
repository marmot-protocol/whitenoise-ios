import SwiftUI

struct LinkPreviewCard: View {
    let url: URL
    let isFromMe: Bool
    let onOpen: () -> Void

    @Environment(\.timelineRowIsVisible) private var isTimelineRowVisible
    @Environment(\.displayScale) private var displayScale
    @State private var metadata: LinkPreviewMetadata?
    @State private var image: UIImage?
    @State private var imageFailed = false

    init(url: URL, isFromMe: Bool, onOpen: @escaping () -> Void) {
        self.url = url
        self.isFromMe = isFromMe
        self.onOpen = onOpen
        _metadata = State(initialValue: LinkPreviewLoader.cachedMetadata(for: url) ?? nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let metadata {
                Button(action: onOpen) {
                    LinkPreviewCardContent(
                        title: metadata.title,
                        host: LinkPreviewCardContent.host(for: url),
                        image: image,
                        showsImageSlot: metadata.imageURL != nil && !imageFailed,
                        isFromMe: isFromMe
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, MessageBubbleReplyLayout.cardOuterInset)
                .padding(.top, MessageBubbleReplyLayout.cardOuterInset)
                .frame(width: MessageBubbleReplyLayout.richBubbleWidth, alignment: .leading)
            } else {
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .task(id: LinkPreviewTaskID(url: url, isVisible: isTimelineRowVisible)) {
            guard isTimelineRowVisible else { return }
            await load()
        }
    }

    private func load() async {
        if metadata == nil {
            guard let loaded = try? await LinkPreviewLoader.metadata(for: url) else { return }
            metadata = loaded
        }
        guard image == nil, !imageFailed, let imageURL = metadata?.imageURL else { return }
        let maxPixelSize = Int((MessageBubbleReplyLayout.richContentWidth * displayScale).rounded(.up))
        do {
            image = try await LinkPreviewLoader.image(for: imageURL, maxPixelSize: maxPixelSize, scale: displayScale)
        } catch {
            if !(error is CancellationError), !Task.isCancelled { imageFailed = true }
        }
    }
}

private struct LinkPreviewTaskID: Equatable {
    let url: URL
    let isVisible: Bool
}

#Preview {
    LinkPreviewCard(url: URL(string: "https://example.com/article")!, isFromMe: false) {}
}
