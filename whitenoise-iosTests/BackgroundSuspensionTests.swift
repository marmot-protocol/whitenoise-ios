import Testing
import Foundation
@testable import whitenoise_ios

/// #81 — the runtime-suspension background task must register an expiration
/// handler so the app ends the task itself instead of being killed uncleanly
/// when background time runs out. Driven at the source level since it touches
/// UIApplication background-task APIs.
struct BackgroundSuspensionTests {

    @Test func backgroundTaskProvidesExpirationHandler() throws {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("whitenoise-ios/whitenoise_iosApp.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        #expect(source.contains("BackgroundRuntimeSuspensionTask(name: \"Suspend Marmot runtime\")"))
        // The handler-less form takes no trailing closure; require the helper to
        // keep the closure form.
        #expect(source.contains("beginBackgroundTask(withName: name) {"))
        // ...and it must end the task it created through the idempotent helper.
        #expect(source.range(
            of: #"func endIfNeeded\(\) \{[\s\S]*?endBackgroundTask\(taskID\)"#,
            options: .regularExpression
        ) != nil)
    }

    @Test func backgroundTaskEndIsSerializedOnMainActor() throws {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("whitenoise-ios/whitenoise_iosApp.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        #expect(source.contains("@MainActor\nprivate final class BackgroundRuntimeSuspensionTask"))
        #expect(source.range(
            of: #"beginBackgroundTask\(withName: name\) \{ \[weak self\] in[\s\S]*?Task \{ @MainActor in[\s\S]*?self\?\.endIfNeeded\(\)"#,
            options: .regularExpression
        ) != nil)
        #expect(source.range(
            of: #"Task \{ @MainActor in[\s\S]*?await suspensionTask\.value[\s\S]*?backgroundTask\.endIfNeeded\(\)"#,
            options: .regularExpression
        ) != nil)
    }
}
