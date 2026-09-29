import Foundation
import MarmotKit
import Testing
@testable import whitenoise_ios

struct MissingKeyPackageInvitationPresentationTests {
    private let account = String(repeating: "c", count: 64)

    @Test func namedRecipientUsesKnownDisplayName() {
        #expect(
            MissingKeyPackageInvitationPresentation.message(accountIdHex: account, knownName: "Alex")
                == "Alex isn't on White Noise yet."
        )
    }

    @Test(arguments: [nil, "", "   ", String(repeating: "d", count: 64)])
    func unusableNameFallsBackToGenericCopy(knownName: String?) {
        #expect(
            MissingKeyPackageInvitationPresentation.message(accountIdHex: account, knownName: knownName)
                == "This user isn't on White Noise yet."
        )
    }

    @Test func copyNeverMentionsProtocolTerms() {
        for name in ["Alex", nil] {
            let message = MissingKeyPackageInvitationPresentation.message(accountIdHex: account, knownName: name)
                .lowercased()
            #expect(!message.contains("key package"))
            #expect(!message.contains("compatible"))
            #expect(!message.contains("npub"))
        }
    }

    @Test func extractsAccountOnlyFromMissingKeyPackage() {
        #expect(
            MissingKeyPackageInvitationPresentation.accountIdHex(for: MarmotKitError.MissingKeyPackage(account: account))
                == account
        )
        #expect(MissingKeyPackageInvitationPresentation.accountIdHex(for: MarmotKitError.Runtime(details: "offline")) == nil)
        #expect(MissingKeyPackageInvitationPresentation.accountIdHex(for: CancellationError()) == nil)
    }
}

@MainActor
struct NewGroupMissingKeyPackageTests {
    private let peerHex = String(repeating: "c", count: 64)

    private func makeAppState(client: MarmotClient, knownName: String?, defaults: UserDefaults) -> AppState {
        let appState = AppState(client: client)
        appState.activeAccountRef = "account"
        appState.profileStore.contactNicknameDefaults = defaults
        appState.profileStore.profileProjectionCache[peerHex] = ProfileDisplayProjection(
            profile: knownName.map {
                UserProfileMetadataFfi(
                    name: nil, displayName: $0, about: nil, picture: nil, banner: nil, nip05: nil, lud16: nil
                )
            },
            projectedName: nil,
            localAccountLabel: nil
        )
        return appState
    }

    private func makeModel() -> (NewChatFlowViewModel, MemberRefFfi) {
        let model = NewChatFlowViewModel()
        let member = MemberRefFfi(memberRef: "npub1alex", accountIdHex: peerHex, npub: "npub1alex")
        model.groupSelection.add(member)
        let peerHex = peerHex
        model.createGroupForTesting = { _, _, _, _ in
            throw MarmotKitError.MissingKeyPackage(account: peerHex)
        }
        return (model, member)
    }

    @Test func namedMissingKeyPackageToastsAndKeepsSelectionForRetry() async throws {
        let client = try MarmotClient.testClient()
        defer { try? FileManager.default.removeItem(atPath: client.rootPath) }
        let suiteName = "MissingKeyPackage.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = makeAppState(client: client, knownName: "Alex", defaults: defaults)
        let (model, member) = makeModel()

        var opened: String?
        await model.createGroup(name: "Test", description: "", retentionSeconds: 0, using: appState) { opened = $0 }
        #expect(opened == nil)
        #expect(!model.isCreatingGroup)
        #expect(model.groupCreateError == "Alex isn't on White Noise yet.")
        #expect(appState.activeToast?.title == "Couldn't create chat")
        #expect(appState.activeToast?.message == "Alex isn't on White Noise yet.")
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

    @Test func unnamedMissingKeyPackageUsesGenericCopy() async throws {
        let client = try MarmotClient.testClient()
        defer { try? FileManager.default.removeItem(atPath: client.rootPath) }
        let suiteName = "MissingKeyPackage.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = makeAppState(client: client, knownName: nil, defaults: defaults)
        let (model, member) = makeModel()

        await model.createGroup(name: "Test", description: "", retentionSeconds: 0, using: appState) { _ in }
        #expect(model.groupCreateError == "This user isn't on White Noise yet.")
        #expect(appState.activeToast?.title == "Couldn't create chat")
        #expect(appState.activeToast?.message == "This user isn't on White Noise yet.")
        #expect(model.groupSelection.memberRefs == [member.memberRef])
        try await client.marmot.shutdownAndClose()
    }
}
