import Foundation
import Testing
@testable import darkmatter_ios

/// #247 — chat-list and account relay-list storage reads must go through
/// MarmotClient async wrappers so generated synchronous FFI does not run on
/// MainActor-bound screens.
struct MarmotClientStorageReadOffloadTests {

    @Test func chatListAndRelayListReadsUseAsyncMarmotClientWrappers() throws {
        let marmotClientSource = try sourceString("darkmatter-ios/Core/MarmotClient.swift")

        #expect(sourceContains(
            #"func chatList\(\s*accountRef: String,\s*includeArchived: Bool\s*\) async throws -> \[ChatListRowFfi\][\s\S]*Task\.detached\(priority: \.utility\)[\s\S]*marmot\.chatList\("#,
            in: marmotClientSource
        ))
        #expect(sourceContains(
            #"func accountRelayLists\(accountRef: String\) async throws -> AccountRelayListsFfi[\s\S]*Task\.detached\(priority: \.utility\)[\s\S]*marmot\.accountRelayLists\("#,
            in: marmotClientSource
        ))

        for relativePath in [
            "darkmatter-ios/Chats/ChatsListViewModel.swift",
            "darkmatter-ios/Diagnostics/DiagnosticsView.swift",
            "darkmatter-ios/Settings/KeyPackagesView.swift",
            "darkmatter-ios/Settings/RelaysView.swift",
        ] {
            let source = try sourceString(relativePath)
            #expect(!source.contains("appState.marmot.chatList("), "\(relativePath) still calls sync chatList FFI directly")
            #expect(!source.contains("appState.marmot.accountRelayLists("), "\(relativePath) still calls sync accountRelayLists FFI directly")
        }
    }

    private func sourceString(_ relativePath: String) throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func sourceContains(_ pattern: String, in source: String) -> Bool {
        source.range(of: pattern, options: .regularExpression) != nil
    }
}
