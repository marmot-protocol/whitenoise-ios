import Foundation

/// Groups a profile subject shares with the active account, including their
/// direct-message chats. Derived from the same screen-lifetime snapshots the
/// recipient directory loads.
nonisolated enum SharedGroupsProjection {
    struct SharedGroup: Equatable, Identifiable {
        let groupIdHex: String
        let title: String
        let avatarUrl: String?
        let imageHashHex: String?
        let memberCount: Int
        let isDirectMessage: Bool
        var pendingConfirmation: Bool = false

        var id: String { groupIdHex }
    }

    static func sharedGroups(
        snapshots: [RecipientGroupSnapshot],
        targetAccountIdHex: String?,
        myAccountIdHex: String?
    ) -> [SharedGroup] {
        guard let target = normalized(targetAccountIdHex), let mine = normalized(myAccountIdHex),
              target != mine
        else { return [] }
        return snapshots
            .filter { snapshot in
                guard snapshot.isSelfMember,
                      !snapshot.pendingConfirmation,
                      snapshot.memberIdsHex.count >= 2
                else { return false }
                let roster = Set(snapshot.memberIdsHex.map { $0.lowercased() })
                return roster.contains(target) && roster.contains(mine)
            }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
            .map { snapshot in
                SharedGroup(
                    groupIdHex: snapshot.groupIdHex,
                    title: snapshot.title,
                    avatarUrl: snapshot.pendingConfirmation ? nil : snapshot.avatarUrl,
                    imageHashHex: snapshot.pendingConfirmation ? nil : snapshot.imageHashHex,
                    memberCount: snapshot.memberIdsHex.count,
                    isDirectMessage: snapshot.sanitizedName == nil
                        && snapshot.memberIdsHex.count == 2,
                    pendingConfirmation: snapshot.pendingConfirmation
                )
            }
    }

    /// Groups the viewer could add the subject to: named groups where the
    /// viewer is an admin member and the subject isn't on the roster. The
    /// engine still enforces admin rights on the invite itself.
    static func addableGroups(
        snapshots: [RecipientGroupSnapshot],
        targetAccountIdHex: String?,
        myAccountIdHex: String?
    ) -> [SharedGroup] {
        guard let target = normalized(targetAccountIdHex), let mine = normalized(myAccountIdHex),
              target != mine
        else { return [] }
        return snapshots
            .filter { snapshot in
                guard snapshot.sanitizedName != nil,
                      snapshot.isSelfMember,
                      !snapshot.pendingConfirmation,
                      !snapshot.memberIdsHex.isEmpty
                else { return false }
                let roster = Set(snapshot.memberIdsHex.map { $0.lowercased() })
                let admins = Set(snapshot.adminIdsHex.map { $0.lowercased() })
                return admins.contains(mine) && roster.contains(mine) && !roster.contains(target)
            }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
            .map { snapshot in
                SharedGroup(
                    groupIdHex: snapshot.groupIdHex,
                    title: snapshot.title,
                    avatarUrl: snapshot.pendingConfirmation ? nil : snapshot.avatarUrl,
                    imageHashHex: snapshot.pendingConfirmation ? nil : snapshot.imageHashHex,
                    memberCount: snapshot.memberIdsHex.count,
                    isDirectMessage: false,
                    pendingConfirmation: snapshot.pendingConfirmation
                )
            }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
