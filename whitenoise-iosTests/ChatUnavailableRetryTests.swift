import Testing
import Foundation
@testable import whitenoise_ios

/// #71 — the timed-out "Chat unavailable" state must offer a Retry that clears
/// the timeout, instead of being a dead end. Source-level since it's a SwiftUI
/// view branch.
struct ChatUnavailableRetryTests {

    @Test func timedOutStateOffersRetryThatClearsTimeout() throws {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("whitenoise-ios/Chats/ChatsListView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        #expect(source.range(
            of: #"else if timedOut \{[\s\S]*?Button\("Retry"\) \{ timedOut = false \}"#,
            options: .regularExpression
        ) != nil)
    }
}
