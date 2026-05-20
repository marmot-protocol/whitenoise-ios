import SwiftUI
import MarmotKit

/// One row in the chats list. Renders 2-member groups in "DM" style (other
/// member's identity in place of group name) and N>2 groups by group name.
struct ChatRow: View {
    let chat: AppGroupRecordFfi

    var body: some View {
        HStack(spacing: 12) {
            AvatarBubble(seed: chat.groupIdHex, title: title)
                .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)
        }
        .padding(.vertical, 4)
    }

    private var title: String {
        if !chat.name.isEmpty { return chat.name }
        return IdentityFormatter.short(chat.groupIdHex)
    }

    private var subtitle: String {
        if !chat.description.isEmpty { return chat.description }
        return "\(chat.relays.count) relays · \(chat.admins.count) admin\(chat.admins.count == 1 ? "" : "s")"
    }
}

/// Circular avatar placeholder. Deterministic color from a seed string so a
/// given group/person keeps the same color across launches.
struct AvatarBubble: View {
    let seed: String
    let title: String

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: [color.opacity(0.85), color.opacity(0.5)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
            Text(initials)
                .font(.headline)
                .foregroundStyle(.white)
        }
    }

    private var initials: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "?" }
        let parts = trimmed.split(separator: " ", maxSplits: 1)
        let first = parts.first?.first.map(String.init) ?? ""
        let second = parts.count > 1 ? (parts[1].first.map(String.init) ?? "") : ""
        let combined = (first + second).uppercased()
        return combined.isEmpty ? "?" : combined
    }

    private var color: Color {
        let palette: [Color] = [.indigo, .blue, .teal, .green, .orange, .pink, .purple, .red]
        let hash = seed.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[abs(hash) % palette.count]
    }
}
