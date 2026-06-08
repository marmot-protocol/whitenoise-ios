import Testing
import Foundation
@testable import darkmatter_ios

/// #44 — the scroll-to-bottom button must do a single fluid animated scroll, not
/// the old fragile triple DispatchQueue.main instant jump. Source-level since
/// it's SwiftUI scroll plumbing.
struct ScrollToBottomFluidTests {

    @Test func scrollToBottomButtonAnimatesWithoutDispatchHack() throws {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("darkmatter-ios/Conversation/ConversationView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        // jumpToBottom must be a single animated scroll with no DispatchQueue hops.
        let bodyPattern = #"private func jumpToBottom\(proxy: ScrollViewProxy\) \{[\s\S]*?scrollToBottom\(proxy: proxy, animated: true\)[\s\S]*?\n    \}"#
        guard let range = source.range(of: bodyPattern, options: .regularExpression) else {
            Issue.record("jumpToBottom did not match the expected single animated scroll shape")
            return
        }
        let body = String(source[range])
        #expect(!body.contains("DispatchQueue.main"))
        #expect(!body.contains("animated: false"))
    }
}
