import SwiftUI
import MarmotKit

struct GroupMemberRow: View {
    let member: AppGroupMemberRecordFfi
    let isAdmin: Bool

    var body: some View {
        HStack(spacing: 12) {
            AvatarBubble(seed: member.memberIdHex, title: displayName)
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(displayName)
                        .font(.body)
                    if member.local {
                        Text("You")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.tint.opacity(0.18), in: Capsule())
                            .foregroundStyle(.tint)
                    }
                    if isAdmin {
                        Text("Admin")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.18), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                Text(IdentityFormatter.short(member.memberIdHex))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 2)
    }

    private var displayName: String {
        if let account = member.account, !account.isEmpty {
            return IdentityFormatter.short(account)
        }
        return IdentityFormatter.short(member.memberIdHex)
    }
}
