import Testing
import Foundation
@testable import darkmatter_ios

/// #81 — the runtime-suspension background task must register an expiration
/// handler so the app ends the task itself instead of being killed uncleanly
/// when background time runs out. Driven at the source level since it touches
/// UIApplication background-task APIs.
struct BackgroundSuspensionTests {

    @Test func backgroundTaskProvidesExpirationHandler() throws {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("darkmatter-ios/darkmatter_iosApp.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        // The handler-less form takes no trailing closure; require the closure form.
        #expect(source.contains("beginBackgroundTask(withName: \"Suspend Marmot runtime\") {"))
        // ...and it must end the task it created.
        #expect(source.range(
            of: #"beginBackgroundTask\(withName: "Suspend Marmot runtime"\) \{[\s\S]*?endBackgroundTask\(taskID\)"#,
            options: .regularExpression
        ) != nil)
    }
}
