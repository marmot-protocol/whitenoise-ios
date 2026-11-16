import MarmotKit
import SwiftUI

/// The seven emoji both devices show while linking. People compare the
/// pictures; MDK's English description is the caption and the spoken label.
struct DeviceLinkCodeView: View {
    let code: [DeviceLinkEmojiFfi]

    @ScaledMetric(relativeTo: .largeTitle) private var emojiSize: CGFloat = 40
    @ScaledMetric(relativeTo: .caption) private var cellWidth: CGFloat = 68

    var body: some View {
        // Four over three keeps the order easy to compare line by line.
        VStack(spacing: 16) {
            row(Array(code.prefix(4)), offset: 0)
            if code.count > 4 {
                row(Array(code.dropFirst(4)), offset: 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Emoji to compare"))
    }

    private func row(_ items: [DeviceLinkEmojiFfi], offset: Int) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                VStack(spacing: 4) {
                    Text(verbatim: item.emoji)
                        .font(.system(size: emojiSize))
                    Text(verbatim: item.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
                .frame(width: cellWidth)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: item.description))
                .accessibilityValue(Text(L10n.formatted("%lld of %lld", Int64(offset + index + 1), Int64(code.count))))
            }
        }
    }
}

/// A large symbol over a title and explanation, for the steps of a link.
struct DeviceLinkStatusHeader: View {
    let systemImage: String
    var tint: Color = .accentColor
    let title: String
    let message: String?
    var showsProgress = false

    var body: some View {
        VStack(spacing: 12) {
            if showsProgress {
                ProgressView()
                    .controlSize(.large)
                    .frame(height: 56)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 48, weight: .regular))
                    .foregroundStyle(tint)
                    .frame(height: 56)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            if let message {
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
