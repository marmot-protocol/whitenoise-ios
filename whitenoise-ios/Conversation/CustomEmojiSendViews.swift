import SwiftUI
import UIKit

/// A picker cell's custom emoji image, loaded through the conversation's
/// custom emoji store exactly as an inline message emoji is. Shows the
/// literal `:shortcode:` until (or unless) the image loads, and never shows
/// an image decoded under another account, runtime or chat.
struct CustomEmojiPickerImage: View {
    @Environment(\.customEmojiStore) private var store
    @Environment(\.displayScale) private var displayScale
    @ScaledMetric(relativeTo: .title) private var pointSize: CGFloat = 29

    let sendable: CustomEmojiSendable

    @State private var loaded: (key: CustomEmojiImageKey, image: UIImage)?

    private struct LoadID: Equatable {
        let scope: CustomEmojiScope?
        let itemID: String
        let pixelSize: Int
        let policyRevision: String
    }

    var body: some View {
        let scope = store?.currentScope
        let size = pixelSize
        Group {
            if let loaded, let scope, loaded.key == CustomEmojiImageKey(scope: scope, itemID: sendable.source.id, pixelSize: size) {
                Image(uiImage: loaded.image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: pointSize, height: pointSize)
            } else {
                Text(verbatim: sendable.token)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(minHeight: pointSize)
            }
        }
        .task(id: LoadID(scope: scope, itemID: sendable.source.id, pixelSize: size,
                         policyRevision: MediaAutoDownloadStore.shared.attachmentPolicyRevision)) {
            guard let store, scope != nil else { return }
            guard let result = await store.inlineImage(
                for: sendable.source,
                pixelSize: size,
                scale: displayScale,
                policyRevision: MediaAutoDownloadStore.shared.attachmentPolicyRevision
            ), !Task.isCancelled, result.key.scope == store.currentScope else { return }
            loaded = result
        }
    }

    private var pixelSize: Int {
        CustomEmojiInlineMetrics.pixelSize(pointSize: pointSize, scale: displayScale)
    }
}

/// Inline, persistent explanation of why a custom emoji message was not
/// sent. The draft is still in the composer, so Send retries it.
struct CustomEmojiSendNotice: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            Label {
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
            }
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.string("Dismiss"))
        }
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .onAppear { AccessibilityNotification.Announcement(message).post() }
        .onChange(of: message) { _, message in AccessibilityNotification.Announcement(message).post() }
    }
}

#Preview("Custom emoji send notice") {
    VStack {
        CustomEmojiSendNotice(message: CustomEmojiSendError.mixedWithAttachments.message, onDismiss: {})
        CustomEmojiSendNotice(message: CustomEmojiSendError.uploadFailed.message, onDismiss: {})
            .environment(\.layoutDirection, .rightToLeft)
    }
}
