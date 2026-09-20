import Foundation
import Testing
import MarmotKit
@testable import whitenoise_ios

@MainActor
@Suite(.serialized)
struct Marmot0104BindingTests {
    @Test func acceptedTokenSurvivesRestartAndRejectsChangedRequests() async throws {
        let client = try MarmotClient.testClient()
        let watchdog = MarmotFixtureWatchdog.start("Durable token test stalled", breaking: client)
        defer { watchdog.cancel() }
        do {
            try await client.startRuntime()
            let account = try await client.marmot.createIdentityWithProfile(
                defaultRelays: client.relayUrls, bootstrapRelays: client.relayUrls).account
            let group = try await client.createGroupWithOptionsDetailed(accountRef: account.label,
                name: "Local admission", memberRefs: [], options: CreateGroupOptionsFfi(
                    description: nil, initialImage: nil, disappearingMessageSecs: 0))
            let token = UUID().uuidString
            let accepted = try await client.sendTextWithClientToken(accountRef: account.label,
                groupIdHex: group.groupIdHex, text: "Durable message", clientToken: token)
            let repeated = try await client.sendTextWithClientToken(accountRef: account.label,
                groupIdHex: group.groupIdHex, text: "Durable message", clientToken: token)
            #expect(accepted == repeated)
            #expect(accepted.clientToken == token)
            #expect(!accepted.messageIdHex.isEmpty)
            #expect(try await client.localSendStatus(accountRef: account.label,
                groupIdHex: group.groupIdHex, clientToken: token) != nil)
            do {
                _ = try await client.sendTextWithClientToken(accountRef: account.label,
                    groupIdHex: group.groupIdHex, text: "Changed request", clientToken: token)
                Issue.record("A token must not be reassigned to a different request")
            } catch MarmotKitError.Runtime {}
            let window = try await client.openConversationWindow(accountRef: account.label, groupIdHex: group.groupIdHex)
            let snapshot = try #require(window.snapshot())
            #expect(snapshot.messages.filter { $0.timeline.clientToken == token }.count == 1)
            await window.cancel()
            try await client.marmot.shutdownAndClose()
            let restarted = try MarmotClient(rootPath: client.rootPath, relayUrls: client.relayUrls)
            do {
                let status = try await restarted.localSendStatus(accountRef: account.label,
                    groupIdHex: group.groupIdHex, clientToken: token)
                #expect(status != nil)
                try await restarted.marmot.shutdownAndClose()
            } catch {
                try? await restarted.marmot.shutdownAndClose()
                throw error
            }
        } catch {
            try? await client.marmot.shutdownAndClose()
            throw error
        }
    }

}
