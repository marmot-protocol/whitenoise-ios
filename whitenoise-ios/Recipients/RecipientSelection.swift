import Foundation
import MarmotKit

/// Ordered multi-select of recipients for New Group and Add Members. Owned by
/// the flow host so the selection survives navigation between the picker and
/// setup steps. Dedup and exclusion reuse the staging rules the reference
/// input already enforces (normalized account id, live-list check).
@MainActor
@Observable
final class RecipientSelection {
    // Avoid the isolated-deinit task-local crash on older Swift runtimes (including iOS 26.2).
    // https://github.com/swiftlang/swift/issues/88036
    nonisolated deinit {}

    private(set) var members: [MemberRefFfi] = []
    var count: Int { members.count }
    var isEmpty: Bool { members.isEmpty }
    var memberRefs: [String] { members.map(\.memberRef) }

    func isSelected(accountIdHex: String) -> Bool {
        let normalized = Self.normalized(accountIdHex)
        return members.contains { Self.normalized($0.accountIdHex) == normalized }
    }

    /// Adds or removes a person. Returns `false` when the person is excluded
    /// (self, or already in the group being extended).
    @discardableResult
    func toggle(_ member: MemberRefFfi, excludedAccountIds: Set<String> = []) -> Bool {
        if isSelected(accountIdHex: member.accountIdHex) {
            remove(accountIdHex: member.accountIdHex)
            return true
        }
        return add(member, excludedAccountIds: excludedAccountIds)
    }

    @discardableResult
    func add(_ member: MemberRefFfi, excludedAccountIds: Set<String> = []) -> Bool {
        switch AddMembersPresentation.stage(
            member,
            existingMembers: members,
            excludedAccountIds: excludedAccountIds
        ) {
        case .added(let updated, _):
            members = updated
            return true
        case .duplicate:
            return true
        case .blocked, .empty, .invalid:
            return false
        }
    }

    func remove(accountIdHex: String) {
        let normalized = Self.normalized(accountIdHex)
        members.removeAll { Self.normalized($0.accountIdHex) == normalized }
    }

    func removeAll() {
        members = []
    }

    static func member(for candidate: RecipientCandidate) -> MemberRefFfi {
        MemberRefFfi(
            memberRef: candidate.npub,
            accountIdHex: candidate.accountIdHex,
            npub: candidate.npub
        )
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
