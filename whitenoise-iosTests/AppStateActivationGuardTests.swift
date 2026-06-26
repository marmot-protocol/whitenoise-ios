import Foundation
import Testing
@testable import whitenoise_ios

struct AppStateActivationGuardTests {
    @Test func activateAccountDeduplicatesInFlightReactivationBeforeAwaitingSignIn() throws {
        let source = try sourceString("whitenoise-ios/Core/AppState.swift")

        #expect(source.contains("private var activatingAccountRefs = Set<String>()"))

        let functionStart = try #require(source.range(of: "func activateAccount(_ accountRef: String) async {"))
        let functionEnd = try #require(source.range(
            of: "/// Signs out of the active account",
            range: functionStart.upperBound..<source.endIndex
        ))
        let body = source[functionStart.lowerBound..<functionEnd.lowerBound]

        let activeGuard = try #require(body.range(of: "guard accountRef != activeAccountRef else { return }"))
        let accountLookup = try #require(body.range(
            of: "guard let account = accounts.first(where: { $0.label == accountRef }) else { return }"
        ))
        let inFlightGuard = try #require(body.range(
            of: "guard activatingAccountRefs.insert(accountRef).inserted else { return }"
        ))
        let cleanup = try #require(body.range(of: "defer { activatingAccountRefs.remove(accountRef) }"))
        let signIn = try #require(body.range(of: "try await marmot.signInAccount(accountRef: accountRef)"))

        #expect(activeGuard.lowerBound < accountLookup.lowerBound)
        #expect(accountLookup.lowerBound < inFlightGuard.lowerBound)
        #expect(inFlightGuard.lowerBound < cleanup.lowerBound)
        #expect(cleanup.lowerBound < signIn.lowerBound)
    }

    private func sourceString(_ relativePath: String) throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}