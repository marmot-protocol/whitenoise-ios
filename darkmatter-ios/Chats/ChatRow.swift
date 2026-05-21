import SwiftUI
import MarmotKit

/// One row in the chats list. Renders 2-member groups in "DM" style (other
/// member's identity in place of group name) and N>2 groups by group name.
struct ChatRow: View {
    @Environment(AppState.self) private var appState
    let chat: AppGroupRecordFfi

    var body: some View {
        HStack(spacing: 12) {
            AvatarBubble(seed: chat.groupIdHex, title: title, pictureURL: avatarURL)
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
        // For a "DM" (no group name), prefer the first admin's display name
        // when we have one cached — it'll usually be the other party.
        if let firstAdmin = chat.admins.first {
            return appState.displayName(forAccountIdHex: firstAdmin)
        }
        return IdentityFormatter.short(chat.groupIdHex)
    }

    private var subtitle: String {
        if !chat.description.isEmpty { return chat.description }
        return "\(chat.relays.count) relays · \(chat.admins.count) admin\(chat.admins.count == 1 ? "" : "s")"
    }

    /// For a DM (no group name), use the other party's avatar when known.
    private var avatarURL: URL? {
        guard chat.name.isEmpty, let firstAdmin = chat.admins.first else { return nil }
        return appState.avatarURL(forAccountIdHex: firstAdmin)
    }
}

/// Circular avatar. Renders the profile picture when a URL is provided,
/// otherwise falls back to initials over a deterministic color derived from
/// the seed string (so a given group/person keeps the same color).
struct AvatarBubble: View {
    let seed: String
    let title: String
    var pictureURL: URL? = nil

    var body: some View {
        Circle()
            .fill(LinearGradient(
                colors: [color.opacity(0.85), color.opacity(0.5)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            .overlay {
                if let pictureURL {
                    AsyncImage(url: pictureURL) { phase in
                        switch phase {
                        case .success(let image):
                            // Fill the circle edge-to-edge, aspect-preserved
                            // and center-cropped. The overlay sizes the image
                            // to the circle's bounds; clipShape crops overflow.
                            image
                                .resizable()
                                .scaledToFill()
                        case .empty, .failure:
                            initialsView
                        @unknown default:
                            initialsView
                        }
                    }
                } else {
                    initialsView
                }
            }
            .clipShape(Circle())
    }

    private var initialsView: some View {
        Text(initials)
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
