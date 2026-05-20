import SwiftUI
import MarmotKit

/// One chat bubble. Aligned left or right depending on direction; uses
/// `.glassEffect()` on iOS 26 for the Messages-app material.
struct MessageBubble: View {
    let record: AppMessageRecordFfi
    let isFromMe: Bool

    init(record: AppMessageRecordFfi) {
        self.record = record
        self.isFromMe = record.direction == "out"
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if isFromMe { Spacer(minLength: 48) }

            VStack(alignment: isFromMe ? .trailing : .leading, spacing: 4) {
                if !isFromMe {
                    Text(IdentityFormatter.short(record.sender))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 12)
                }

                Text(record.plaintext)
                    .font(.body)
                    .foregroundStyle(isFromMe ? Color.white : Color.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(bubbleBackground)
                    .clipShape(.rect(cornerRadius: 18))
                    .textSelection(.enabled)
            }

            if !isFromMe { Spacer(minLength: 48) }
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        if isFromMe {
            LinearGradient(
                colors: [.blue, .indigo],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            Color(.secondarySystemBackground)
        }
    }
}
