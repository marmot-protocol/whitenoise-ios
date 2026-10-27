import Foundation
import MarmotKit
import Testing
@testable import whitenoise_ios

/// Each `nextCancellable()` in the handwritten `CancellablePresentedChatList`
/// adapter binds its own native `next` symbol and converter, so each
/// subscription type needs its own cancellation check (AGENTS.md, Rust
/// Bindings). `RuntimeOwnershipTests` covers `PresentedChatListSubscription`.
/// These tests assert only that a pending wait ends in `CancellationError`
/// and leaves the runtime usable.
@MainActor
@Suite(.serialized, .marmotRuntimeConcurrencyLimit)
struct CancellableSubscriptionAdapterTests {
    enum Adapter: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case conversationWindow, accountAttention, blockList, chatListWindow
        var testDescription: String { rawValue }
    }

    @Test(arguments: Adapter.allCases)
    func cancellingAPendingWaitThrowsCancellationAndKeepsTheRuntimeUsable(_ adapter: Adapter) async throws {
        try await withTestClient { client in
            let watchdog = MarmotFixtureWatchdog.start(
                "Cancelling \(adapter.rawValue) required a runtime shutdown to unblock", breaking: client)
            defer { watchdog.cancel() }
            try await client.startRuntime()
            let account = try await client.marmot.createIdentityWithProfile(
                defaultRelays: ["wss://relay.invalid.test"], bootstrapRelays: ["wss://relay.invalid.test"]
            ).account
            let group = try await client.createGroupWithOptionsDetailed(
                accountRef: account.label, name: "Adapter", memberRefs: [],
                options: CreateGroupOptionsFfi(description: nil, initialImage: nil, disappearingMessageSecs: 0)
            )

            // Consume the initial snapshot so the next native wait has no event pending.
            let wait: @Sendable () async throws -> Void
            switch adapter {
            case .conversationWindow:
                let window = try await client.openConversationWindow(
                    accountRef: account.label, groupIdHex: group.groupIdHex)
                _ = try #require(window.snapshot())
                wait = { while try await window.nextCancellable() != nil {} }
            case .accountAttention:
                let attention = try await client.subscribeAccountAttention()
                _ = try #require(attention.snapshot())
                wait = { while try await attention.nextCancellable() != nil {} }
            case .blockList:
                let blocks = try client.marmot.subscribeBlockedUsers(accountRef: account.label)
                _ = try #require(blocks.snapshot())
                wait = { while try await blocks.nextCancellable() != nil {} }
            case .chatListWindow:
                let window = try await client.marmot.openChatListWindow(
                    accountRef: account.label, view: .chats, initialRows: 1)
                _ = try #require(window.snapshot())
                wait = { while try await window.nextCancellable() != nil {} }
            }

            for _ in 0..<8 {
                let reader = Task.detached { try await wait() }
                await Task.yield()
                reader.cancel()
                await #expect(throws: CancellationError.self) { try await reader.value }
            }

            #expect(try await client.listAccounts().contains { $0.accountIdHex == account.accountIdHex })
            try await client.marmot.shutdownAndClose()
            #expect(client.marmot.storageIsClosed())
        }
    }
}
