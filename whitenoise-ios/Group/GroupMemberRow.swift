import MarmotKit
import SwiftUI

struct GroupMemberRow: View {
    @Environment(AppState.self) private var appState
    let member: AppGroupMemberRecordFfi
    let isAdmin: Bool

    var body: some View {
        HStack(spacing: 12) {
            AvatarBubble(seed: member.memberIdHex, title: displayName, pictureURL: avatarURL)
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
                Text(secondaryIdentity)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 2)
    }

    private var displayName: String {
        if let account = member.account, !account.isEmpty {
            return appState.displayName(forAccountIdHex: account)
        }
        return IdentityFormatter.short(member.memberIdHex)
    }

    private var avatarURL: URL? {
        guard let account = member.account, !account.isEmpty else { return nil }
        return appState.avatarURL(forAccountIdHex: account)
    }

    /// npub for accounts that map to a Nostr key; MLS member ids (no mapped
    /// account) stay as short hex since they aren't pubkeys.
    private var secondaryIdentity: String {
        if let account = member.account, !account.isEmpty {
            return appState.shortNpub(forAccountIdHex: account)
        }
        return IdentityFormatter.short(member.memberIdHex)
    }
}

struct GroupMemberDetailsRow: View {
    @Environment(AppState.self) private var appState
    let member: GroupMemberDetailsFfi

    var body: some View {
        HStack(spacing: 12) {
            AvatarBubble(seed: member.memberIdHex, title: displayName, pictureURL: avatarURL)
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(displayName)
                        .font(.body)
                    if member.isSelf {
                        Text("You")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.tint.opacity(0.18), in: Capsule())
                            .foregroundStyle(.tint)
                    }
                    if member.isAdmin {
                        Text("Admin")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.18), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                Text(IdentityFormatter.short(member.npub))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 2)
    }

    private var displayName: String {
        GroupMemberDetailsPresentation.displayName(for: member, appState: appState)
    }

    private var avatarURL: URL? {
        GroupMemberDetailsPresentation.avatarURL(for: member, appState: appState)
    }
}

enum GroupMemberDetailsPresentation {
    static func profileAccountIdHex(for member: GroupMemberDetailsFfi) -> String {
        guard let account = member.account, !account.isEmpty else {
            return member.memberIdHex
        }
        return account
    }

    @MainActor
    static func displayName(for member: GroupMemberDetailsFfi, appState: AppState) -> String {
        if let name = ProfileSanitizer.displayName(member.displayName) {
            return name
        }
        let accountIdHex = profileAccountIdHex(for: member)
        return appState.knownDisplayName(forAccountIdHex: accountIdHex)
            ?? IdentityFormatter.short(accountIdHex)
    }

    @MainActor
    static func avatarURL(for member: GroupMemberDetailsFfi, appState: AppState) -> URL? {
        appState.avatarURL(forAccountIdHex: profileAccountIdHex(for: member))
    }
}
