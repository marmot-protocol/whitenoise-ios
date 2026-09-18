import Foundation
import MarmotKit
import OSLog

nonisolated struct GroupMembershipPageLoadResult {
    let memberIdsByGroupId: [String: [String]]
    let adminIdsByGroupId: [String: [String]]
    let firstUnresolvedError: Error?
    let pageReadCount: Int
    let fallbackReadCount: Int
}

/// Batches the common chat-projection membership read while retaining the
/// old per-group fault isolation when one all-or-nothing page fails.
nonisolated enum GroupMembershipPageLoader {
    static let maximumPageSize = 100

    static func pages(for groupIdsHex: [String]) -> [[String]] {
        var seen: Set<String> = []
        let unique = groupIdsHex.filter { seen.insert($0).inserted }
        return stride(from: 0, to: unique.count, by: maximumPageSize).map { start in
            Array(unique[start..<min(start + maximumPageSize, unique.count)])
        }
    }

    static func load(
        groupIdsHex: [String],
        pageRead: ([String]) async throws -> [AppGroupMemberIdsFfi],
        fallbackRead: (String) async throws -> [String]
    ) async throws -> GroupMembershipPageLoadResult {
        var memberIdsByGroupId: [String: [String]] = [:]
        var adminIdsByGroupId: [String: [String]] = [:]
        var firstUnresolvedError: Error?
        var pageReadCount = 0
        var fallbackReadCount = 0

        for page in pages(for: groupIdsHex) {
            try Task.checkCancellation()
            do {
                pageReadCount += 1
                let rows = try await pageRead(page)
                guard rows.count == page.count,
                      zip(rows, page).allSatisfy({ $0.groupIdHex == $1 })
                else {
                    throw GroupMembershipPageResponseError.invalidRows
                }
                for row in rows {
                    memberIdsByGroupId[row.groupIdHex] = row.memberIdsHex
                    adminIdsByGroupId[row.groupIdHex] = row.adminIdsHex
                }
                continue
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A page is atomic in MarmotKit. Recover each requested group
                // independently so one quarantined row cannot blank the rest.
            }

            for groupIdHex in page {
                try Task.checkCancellation()
                do {
                    fallbackReadCount += 1
                    memberIdsByGroupId[groupIdHex] = try await fallbackRead(groupIdHex)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    firstUnresolvedError = firstUnresolvedError ?? error
                }
            }
        }

        return GroupMembershipPageLoadResult(
            memberIdsByGroupId: memberIdsByGroupId,
            adminIdsByGroupId: adminIdsByGroupId,
            firstUnresolvedError: firstUnresolvedError,
            pageReadCount: pageReadCount,
            fallbackReadCount: fallbackReadCount
        )
    }

    private enum GroupMembershipPageResponseError: Error {
        case invalidRows
    }
}

/// Screen-lifetime directory of people derivable from the active account's
/// chat state. Loads the durable chat-list rows plus each group's roster off
/// the MainActor, then projects candidates ordered by recent conversation
/// activity. Rebuilt per screen presentation — Marmot stays the source of
/// truth and nothing here is persisted.
@MainActor
@Observable
final class RecipientDirectory {
    nonisolated private static let loadLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.ipf.whitenoise.ios",
        category: "recipient-directory"
    )

    private(set) var snapshots: [RecipientGroupSnapshot] = []
    private(set) var candidates: [RecipientCandidate] = []
    private(set) var isLoading = false
    private(set) var loadError: String?
    private(set) var searchFieldsByAccountId: [String: RecipientSearch.MatchFields] = [:]
    private var loadedAccountRef: String?
    private var loadedAdminMetadata = false
    private var loadTask: Task<Void, Never>?
    private var loadTaskID: UUID?
    private var loadAccountRef: String?

    private static let profileWarmupLimit = 24

    /// Callers that need the directory before deciding (e.g. DM reuse) can
    /// await this mid-flight: a concurrent load is joined, not skipped.
    func load(
        using appState: AppState,
        force: Bool = false,
        includeAdminMetadata: Bool = false
    ) async {
        guard let accountRef = appState.activeAccountRef else {
            resetForAccountChange()
            return
        }
        if Self.shouldResetForAccountChange(
            loadedAccountRef: loadedAccountRef,
            loadingAccountRef: loadAccountRef,
            requestedAccountRef: accountRef
        ) {
            resetForAccountChange()
        }
        if let loadTask {
            await loadTask.value
        }
        guard appState.activeAccountRef == accountRef else { return }
        if loadedAccountRef == accountRef,
           !force,
           !snapshots.isEmpty,
           !includeAdminMetadata || loadedAdminMetadata {
            return
        }
        guard !isLoading else { return }
        let taskID = UUID()
        loadTaskID = taskID
        loadAccountRef = accountRef
        let task = Task {
            await performLoad(
                accountRef: accountRef,
                taskID: taskID,
                includeAdminMetadata: includeAdminMetadata,
                using: appState
            )
        }
        loadTask = task
        await task.value
        if Self.shouldClearLoadTask(currentTaskID: loadTaskID, completingTaskID: taskID) {
            loadTask = nil
            loadTaskID = nil
            loadAccountRef = nil
        }
    }

    nonisolated static func shouldResetForAccountChange(
        loadedAccountRef: String?,
        loadingAccountRef: String?,
        requestedAccountRef: String
    ) -> Bool {
        if let loadingAccountRef, loadingAccountRef != requestedAccountRef { return true }
        if let loadedAccountRef, loadedAccountRef != requestedAccountRef { return true }
        return false
    }

    nonisolated static func shouldClearLoadTask(
        currentTaskID: UUID?,
        completingTaskID: UUID
    ) -> Bool {
        currentTaskID == completingTaskID
    }

    nonisolated static func loadRequestIsCurrent(
        currentTaskID: UUID?,
        currentAccountRef: String?,
        activeAccountRef: String?,
        completingTaskID: UUID,
        completingAccountRef: String
    ) -> Bool {
        currentTaskID == completingTaskID
            && currentAccountRef == completingAccountRef
            && activeAccountRef == completingAccountRef
    }

    private func performLoad(
        accountRef: String,
        taskID: UUID,
        includeAdminMetadata: Bool,
        using appState: AppState
    ) async {
        guard Self.loadRequestIsCurrent(
            currentTaskID: loadTaskID,
            currentAccountRef: loadAccountRef,
            activeAccountRef: appState.activeAccountRef,
            completingTaskID: taskID,
            completingAccountRef: accountRef
        ) else { return }
        isLoading = true
        loadError = nil
        defer {
            if loadTaskID == taskID {
                isLoading = false
            }
        }
        do {
            let client = try appState.currentMarmotClient()
            let myAccountIdHex = appState.activeAccount?.accountIdHex
            let loaded = try await Self.loadSnapshots(
                client: client,
                accountRef: accountRef,
                includeAdminMetadata: includeAdminMetadata
            )
            let derived = await Self.deriveCandidates(from: loaded, myAccountIdHex: myAccountIdHex)
            try Task.checkCancellation()
            guard Self.loadRequestIsCurrent(
                currentTaskID: loadTaskID,
                currentAccountRef: loadAccountRef,
                activeAccountRef: appState.activeAccountRef,
                completingTaskID: taskID,
                completingAccountRef: accountRef
            ) else { return }
            snapshots = loaded
            candidates = derived
            loadedAccountRef = accountRef
            loadedAdminMetadata = includeAdminMetadata
            refreshSearchFields(using: appState)
            for candidate in derived.prefix(Self.profileWarmupLimit) {
                _ = appState.profile(forAccountIdHex: candidate.accountIdHex)
            }
        } catch is CancellationError {
            return
        } catch {
            guard Self.loadRequestIsCurrent(
                currentTaskID: loadTaskID,
                currentAccountRef: loadAccountRef,
                activeAccountRef: appState.activeAccountRef,
                completingTaskID: taskID,
                completingAccountRef: accountRef
            ) else { return }
            loadError = UserFacingError.message(for: error)
        }
    }

    private func resetForAccountChange() {
        loadTask?.cancel()
        loadTask = nil
        loadTaskID = nil
        loadAccountRef = nil
        isLoading = false
        snapshots = []
        candidates = []
        searchFieldsByAccountId = [:]
        loadedAccountRef = nil
        loadedAdminMetadata = false
        loadError = nil
    }

    /// Snapshot side-effecting profile lookups outside SwiftUI's search hot
    /// path. Screens refresh this once when the profile generation changes;
    /// each keystroke then performs only pure dictionary reads.
    func refreshSearchFields(using appState: AppState) {
        searchFieldsByAccountId = Dictionary(uniqueKeysWithValues: candidates.map { candidate in
            (
                candidate.accountIdHex,
                RecipientSearch.MatchFields(
                    displayName: appState.cachedKnownDisplayName(forAccountIdHex: candidate.accountIdHex),
                    nip05: ContentSanitizer.profileAddress(
                        appState.cachedProfile(forAccountIdHex: candidate.accountIdHex)?.nip05
                    )
                )
            )
        })
    }

    func matchFields(for candidate: RecipientCandidate) -> RecipientSearch.MatchFields {
        searchFieldsByAccountId[candidate.accountIdHex] ?? .init()
    }

    /// Membership pages collapse up to 100 chat rosters into one worker
    /// command. A failed page falls back per group so one bad row still cannot
    /// blank the directory.
    private nonisolated static func loadSnapshots(
        client: MarmotClient,
        accountRef: String,
        includeAdminMetadata: Bool
    ) async throws -> [RecipientGroupSnapshot] {
        let startedAt = ContinuousClock.now
        let rows = try await client.chatList(accountRef: accountRef, includeArchived: true)
        let membership = try await GroupMembershipPageLoader.load(
            groupIdsHex: rows.map(\.groupIdHex),
            pageRead: { groupIdsHex in
                try await client.groupMemberIdsPage(
                    accountRef: accountRef,
                    groupIdsHex: groupIdsHex
                )
            },
            fallbackRead: { groupIdHex in
                try await client.groupMembers(
                    accountRef: accountRef,
                    groupIdHex: groupIdHex
                ).map(\.memberIdHex)
            }
        )
        var adminIdsByGroupId = membership.adminIdsByGroupId
        if includeAdminMetadata {
            let fallbackRows = rows.filter { adminIdsByGroupId[$0.groupIdHex] == nil }
            let fallbackAdmins = try await loadAdminIds(
                client: client,
                accountRef: accountRef,
                rows: fallbackRows
            )
            adminIdsByGroupId.merge(fallbackAdmins) { _, fallback in fallback }
        }
        let elapsed = startedAt.duration(to: .now).components
        let elapsedMs = Double(elapsed.seconds) * 1_000
            + Double(elapsed.attoseconds) / 1_000_000_000_000_000
        loadLog.debug(
            "membership_projection groups=\(rows.count, privacy: .public) pages=\(membership.pageReadCount, privacy: .public) fallbacks=\(membership.fallbackReadCount, privacy: .public) admin_enrichment=\(includeAdminMetadata, privacy: .public) duration_ms=\(elapsedMs, format: .fixed(precision: 0), privacy: .public)"
        )

        return rows.map { row in
            RecipientGroupSnapshot(
                row: row,
                memberIdsHex: membership.memberIdsByGroupId[row.groupIdHex] ?? [],
                adminIdsHex: includeAdminMetadata
                    ? adminIdsByGroupId[row.groupIdHex] ?? []
                    : []
            )
        }
    }

    private nonisolated static func loadAdminIds(
        client: MarmotClient,
        accountRef: String,
        rows: [ChatListRowFfi]
    ) async throws -> [String: [String]] {
        let eligibleRows = rows.filter {
            ContentSanitizer.groupName($0.groupName) != nil
                && GroupManagementPresentation.isActiveChatListMember($0.selfMembership)
        }
        var adminIdsByGroupId: [String: [String]] = [:]
        try await withThrowingTaskGroup(of: (String, [String]?).self) { group in
            var iterator = eligibleRows.makeIterator()
            var inFlight = 0
            func addNext() {
                guard let row = iterator.next() else { return }
                inFlight += 1
                group.addTask {
                    let roster = try? await client.groupRoster(
                        accountRef: accountRef,
                        groupIdHex: row.groupIdHex
                    )
                    return (
                        row.groupIdHex,
                        roster?.members.filter(\.isAdmin).map(\.memberIdHex)
                    )
                }
            }
            for _ in 0..<4 { addNext() }
            while inFlight > 0 {
                try Task.checkCancellation()
                guard let (groupIdHex, adminIds) = try await group.next() else { break }
                inFlight -= 1
                if let adminIds {
                    adminIdsByGroupId[groupIdHex] = adminIds
                }
                addNext()
            }
        }
        return adminIdsByGroupId
    }

    private nonisolated static func deriveCandidates(
        from snapshots: [RecipientGroupSnapshot],
        myAccountIdHex: String?
    ) async -> [RecipientCandidate] {
        RecipientCandidateDerivation.candidates(from: snapshots, myAccountIdHex: myAccountIdHex)
    }
}
