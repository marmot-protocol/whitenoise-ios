import Testing
import Foundation
@testable import whitenoise_ios
struct AppStateInitRedactionTests {

    private struct LeakyStorageError: Error, CustomStringConvertible {
        var description: String { "keychain path /var/secret/token=hunter2" }
    }

    @Test func storageInitFailureMessageSurfacesTypeNotRawError() {
        let message = AppState.redactedStorageInitFailureMessage(for: LeakyStorageError())

        #expect(message == "Failed to initialize durable Marmot storage (LeakyStorageError)")
        #expect(message.contains("LeakyStorageError"))
        #expect(!message.contains("hunter2"))
        #expect(!message.contains("/var/secret"))
    }

    @Test func runtimeRebuildFailureMessageSurfacesTypeNotRawError() {
        let message = AppState.redactedRuntimeRebuildFailureMessage(for: LeakyStorageError())

        #expect(message == "Failed to rebuild Keychain-backed Marmot runtime (LeakyStorageError)")
        #expect(message.contains("LeakyStorageError"))
        #expect(!message.contains("hunter2"))
        #expect(!message.contains("/var/secret"))
    }
}
