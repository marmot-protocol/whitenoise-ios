import Foundation
import MarmotKit
import Testing
@testable import whitenoise_ios

@MainActor
struct NewChatFlowViewModelTests {
    @Test func finalCreateFailureKeepsSelectionAndAllowsRetry() async throws {
        let client = try MarmotClient.testClient()
        defer { try? FileManager.default.removeItem(atPath: client.rootPath) }
        let appState = AppState(client: client)
        appState.activeAccountRef = "account"
        let model = NewChatFlowViewModel()
        let member = MemberRefFfi(memberRef: "npub1alice", accountIdHex: String(repeating: "a", count: 64), npub: "npub1alice")
        model.groupSelection.add(member)
        model.createGroupForTesting = { _, _, _, _ in
            throw MarmotKitError.Runtime(details: "recipient KeyPackage incompatible")
        }
        var opened: String?
        await model.createGroup(name: "Test", description: "", retentionSeconds: 0, using: appState) { opened = $0 }
        #expect(opened == nil)
        #expect(!model.isCreatingGroup)
        #expect(model.groupCreateError == "Recipient KeyPackage incompatible")
        #expect(appState.activeToast?.title == "Couldn't create chat")
        #expect(appState.activeToast?.message == "Recipient KeyPackage incompatible")
        #expect(model.groupSelection.memberRefs == [member.memberRef])

        model.createGroupForTesting = { _, _, refs, _ in
            #expect(refs == [member.memberRef])
            return "created"
        }
        await model.createGroup(name: "Test", description: "", retentionSeconds: 0, using: appState) { opened = $0 }
        #expect(opened == "created")
        #expect(model.groupCreateError == nil)
        try await client.marmot.shutdownAndClose()
    }
}
