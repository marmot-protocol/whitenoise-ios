import Testing
import Foundation
@testable import whitenoise_ios

/// #44 — the scroll-to-bottom button must do a single fluid animated scroll, not
/// the old fragile triple DispatchQueue.main instant jump. Source-level since
/// it's SwiftUI scroll plumbing.
struct ScrollToBottomFluidTests {

    @Test func scrollToBottomButtonAnimatesWithoutDispatchHack() throws {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("whitenoise-ios/Conversation/ConversationView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        // ConversationView scroll plumbing should stay on structured MainActor
        // tasks rather than reviving the old DispatchQueue timing workaround.
        #expect(!source.contains("DispatchQueue.main"))

        // jumpToBottom must schedule a single animated scroll through the
        // coordinator, not perform an immediate scroll in the button action.
        let bodyPattern = #"private func jumpToBottom\(proxy: ScrollViewProxy\) \{[\s\S]*?scheduleScrollToBottom\([\s\S]*?animated: true,[\s\S]*?reason: \.buttonTap[\s\S]*?\n    \}"#
        guard let range = source.range(of: bodyPattern, options: .regularExpression) else {
            Issue.record("jumpToBottom did not match the expected deferred animated scroll shape")
            return
        }
        let body = String(source[range])
        #expect(!body.contains("animated: false"))
        #expect(!body.contains("scrollToBottom(proxy: proxy"))
    }
}
