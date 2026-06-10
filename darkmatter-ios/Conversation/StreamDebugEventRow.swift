import SwiftUI

/// Inline row for live QUIC agent-stream updates shown during streaming debug.
struct StreamDebugEventRow: View {
    let event: StreamDebugTimelineEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.caption2)
                Text("QUIC · \(event.eventKind)")
                    .font(.caption.weight(.semibold).monospaced())
                Spacer(minLength: 0)
                Text(MessageDebugCategory.streamSignaling.label)
                    .font(.caption2.weight(.semibold))
            }
            Text("stream \(shortStreamId(event.streamId))")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            if !event.detail.isEmpty {
                Text(event.detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
        }
        .foregroundStyle(MessageDebugCategory.streamSignaling.accentColor)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(MessageDebugCategory.streamSignaling.accentColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(MessageDebugCategory.streamSignaling.accentColor.opacity(0.55), lineWidth: 1.5)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }

    private func shortStreamId(_ streamId: String) -> String {
        guard streamId.count > 16 else { return streamId }
        return "\(streamId.prefix(8))…\(streamId.suffix(8))"
    }
}
