import Foundation
import MarmotKit
import Synchronization
import Testing
@testable import whitenoise_ios

/// The directory loads the active profile's people once per screen, joins a
/// load already under way, and never shows one profile's people on another.
@MainActor
struct RecipientDirectoryTests {
    private let alice = hex("a1")
    private let bob = hex("b2")
    private let carol = hex("c3")

    @Test func aLoadUnderWayIsJoinedAndKeptUntilForced() async {
        let reads = RecipientReadsStub(rows: ["account": [chatListRow(groupIdHex: "chat", title: "Chat")]],
                                       members: ["chat": [alice]])
        let gate = AsyncTestCheckpoint()
        reads.holdNextChatList(gate)
        let directory = RecipientDirectory(reads: { _ in reads.reads })
        let appState = Self.appState(account: "account")

        let first = Task { await directory.load(using: appState) }
        await gate.waitUntilPaused()
        let joined = Task {
            await directory.load(using: appState)
            return directory.candidates.map(\.accountIdHex)
        }
        await Task.yield()
        await gate.release()
        await first.value

        // A caller deciding from the directory (DM reuse) waits for the load it joined.
        #expect(await joined.value == [alice])
        await directory.load(using: appState)
        #expect(reads.chatListReads == ["account"])

        await directory.load(using: appState, force: true)
        #expect(reads.chatListReads == ["account", "account"])
    }

    @Test func switchingProfilesMidLoadNeverShowsTheOldProfilesPeople() async {
        let reads = RecipientReadsStub(rows: ["a": [chatListRow(groupIdHex: "chat-a", title: "A")],
                                              "b": [chatListRow(groupIdHex: "chat-b", title: "B")]],
                                       members: ["chat-a": [alice], "chat-b": [bob]])
        let gate = AsyncTestCheckpoint()
        reads.holdNextChatList(gate)
        let directory = RecipientDirectory(reads: { _ in reads.reads })
        let appState = Self.appState(account: "a")

        let stale = Task { await directory.load(using: appState) }
        await gate.waitUntilPaused()
        appState.activeAccountRef = "b"
        await directory.load(using: appState)
        await gate.release()
        await stale.value

        #expect(directory.candidates.map(\.accountIdHex) == [bob])
        #expect(directory.snapshots.map(\.groupIdHex) == ["chat-b"])
        #expect(!directory.isLoading)

        appState.activeAccountRef = nil
        await directory.load(using: appState)
        #expect(directory.candidates.isEmpty)
        #expect(directory.snapshots.isEmpty)
    }

    /// Membership pages are all-or-nothing in MDK, so one unreadable chat must
    /// not blank the rest of the directory or surface as a load error.
    @Test func anUnreadableChatLeavesEveryOtherChatsPeopleListed() async {
        let reads = RecipientReadsStub(rows: ["account": [chatListRow(groupIdHex: "good", title: "Good"),
                                                          chatListRow(groupIdHex: "bad", title: "Bad")]],
                                       members: ["good": [alice]])
        reads.failsMemberPages = true
        let directory = RecipientDirectory(reads: { _ in reads.reads })

        await directory.load(using: Self.appState(account: "account"))

        #expect(directory.loadError == nil)
        #expect(directory.candidates.map(\.accountIdHex) == [alice])
        #expect(directory.snapshots.map(\.groupIdHex).sorted() == ["bad", "good"])
    }

    /// Admins come from the membership page when it reads; otherwise only named
    /// chats the user is still in read their roster.
    @Test func adminMetadataLoadsOnRequestAndFallsBackToRostersOfNamedChats() async {
        let named = chatListRow(groupIdHex: "named", title: "Hiking")
        let unnamed = chatListRow(groupIdHex: "unnamed", title: "Alice", groupName: "")
        let left = chatListRow(groupIdHex: "left", title: "Old Club", selfMembership: .left)
        let reads = RecipientReadsStub(rows: ["account": [named, unnamed, left]],
                                       members: ["named": [alice, bob], "unnamed": [alice], "left": [carol]],
                                       admins: ["named": [bob], "unnamed": [alice], "left": [carol]])
        let directory = RecipientDirectory(reads: { _ in reads.reads })
        let appState = Self.appState(account: "account")

        await directory.load(using: appState)
        #expect(directory.snapshots.allSatisfy { $0.adminIdsHex.isEmpty })
        #expect(reads.rosterReads.isEmpty)

        reads.failsMemberPages = true
        await directory.load(using: appState, includeAdminMetadata: true)

        #expect(reads.chatListReads.count == 2)
        #expect(reads.rosterReads == ["named"])
        #expect(directory.snapshots.first { $0.groupIdHex == "named" }?.adminIdsHex == [bob])
        #expect(directory.snapshots.filter { $0.groupIdHex != "named" }.allSatisfy { $0.adminIdsHex.isEmpty })

        reads.failsMemberPages = false
        await directory.load(using: appState, force: true, includeAdminMetadata: true)
        #expect(reads.rosterReads == ["named"])
        #expect(directory.snapshots.first { $0.groupIdHex == "unnamed" }?.adminIdsHex == [alice])
    }

    @Test func aFailedChatListIsShownAndTheNextLoadRetries() async {
        let reads = RecipientReadsStub(rows: ["account": [chatListRow(groupIdHex: "chat", title: "Chat")]],
                                       members: ["chat": [alice]])
        reads.failingChatLists = 1
        let directory = RecipientDirectory(reads: { _ in reads.reads })
        let appState = Self.appState(account: "account")

        await directory.load(using: appState)
        #expect(directory.loadError != nil)
        #expect(directory.candidates.isEmpty)

        await directory.load(using: appState)
        #expect(directory.loadError == nil)
        #expect(directory.candidates.map(\.accountIdHex) == [alice])
    }

    /// Search reads only these precomputed fields per keystroke.
    @Test func searchFieldsComeFromCachedProfilesOfLoadedPeople() async {
        let reads = RecipientReadsStub(rows: ["account": [chatListRow(groupIdHex: "chat", title: "Chat")]],
                                       members: ["chat": [alice, bob]])
        let directory = RecipientDirectory(reads: { _ in reads.reads })
        let appState = Self.appState(account: "account")
        appState.profileStore.profileProjectionCache[alice] = ProfileDisplayProjection(
            profile: UserProfileMetadataFfi(name: nil, displayName: "Alice Liddell", about: nil, picture: nil,
                                            nip05: "alice@example.com", lud16: nil),
            projectedName: nil, localAccountLabel: nil
        )

        await directory.load(using: appState)

        let fields = Dictionary(uniqueKeysWithValues: directory.candidates.map {
            ($0.accountIdHex, directory.matchFields(for: $0))
        })
        #expect(fields[alice] == .init(displayName: "Alice Liddell", nip05: "alice@example.com"))
        #expect(fields[bob] == .init())
    }

    private static func appState(account: String) -> AppState {
        let appState = AppState.test()
        appState.activeAccountRef = account
        return appState
    }
}

/// Answers the directory's reads from per-account chat rows and per-chat
/// rosters, recording what was read.
private final class RecipientReadsStub: Sendable {
    private struct State {
        var failsMemberPages = false
        var failingChatLists = 0
        var chatListGate: AsyncTestCheckpoint?
        var chatListReads: [String] = []
        var rosterReads: [String] = []
    }

    private let rows: [String: [ChatListRowFfi]]
    private let members: [String: [String]]
    private let admins: [String: [String]]
    private let state = Mutex(State())

    init(rows: [String: [ChatListRowFfi]], members: [String: [String]], admins: [String: [String]] = [:]) {
        self.rows = rows
        self.members = members
        self.admins = admins
    }

    var failsMemberPages: Bool {
        get { state.withLock { $0.failsMemberPages } }
        set { state.withLock { $0.failsMemberPages = newValue } }
    }

    var failingChatLists: Int {
        get { state.withLock { $0.failingChatLists } }
        set { state.withLock { $0.failingChatLists = newValue } }
    }

    var chatListReads: [String] { state.withLock { $0.chatListReads } }
    var rosterReads: [String] { state.withLock { $0.rosterReads } }

    func holdNextChatList(_ gate: AsyncTestCheckpoint) {
        state.withLock { $0.chatListGate = gate }
    }

    var reads: RecipientDirectoryReads {
        RecipientDirectoryReads(
            chatList: { accountRef in
                let (gate, fails) = self.state.withLock { state in
                    state.chatListReads.append(accountRef)
                    defer { state.chatListGate = nil }
                    let fails = state.failingChatLists > 0
                    if fails { state.failingChatLists -= 1 }
                    return (state.chatListGate, fails)
                }
                await gate?.pause()
                if fails { throw StubReadError.failed }
                return self.rows[accountRef] ?? []
            },
            memberIdsPage: { _, groupIdsHex in
                if self.failsMemberPages { throw StubReadError.failed }
                return groupIdsHex.map {
                    AppGroupMemberIdsFfi(groupIdHex: $0, memberIdsHex: self.members[$0] ?? [],
                                         adminIdsHex: self.admins[$0] ?? [])
                }
            },
            memberIds: { _, groupIdHex in
                guard let members = self.members[groupIdHex] else { throw StubReadError.failed }
                return members
            },
            adminIds: { _, groupIdHex in
                self.state.withLock { $0.rosterReads.append(groupIdHex) }
                return self.admins[groupIdHex] ?? []
            }
        )
    }
}

private enum StubReadError: Error { case failed }
