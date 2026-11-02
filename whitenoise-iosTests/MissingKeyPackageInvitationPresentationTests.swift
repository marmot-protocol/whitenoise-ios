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

    @Test func outdatedRecipientIsAskedToUpdateRatherThanInstall() {
        #expect(
            MissingKeyPackageInvitationPresentation.message(accountIdHex: account, knownName: "Alex", reason: .obsoleteOnly)
                == "Alex needs to update their app before they can be invited."
        )
        #expect(
            MissingKeyPackageInvitationPresentation.message(accountIdHex: account, knownName: nil, reason: .obsoleteOnly)
                == "This user needs to update their app before they can be invited."
        )
    }

    @Test func copyNeverMentionsProtocolTerms() {
        for name in ["Alex", nil] {
            for reason in [MissingKeyPackageReasonFfi.notFound, .obsoleteOnly] {
                let message = MissingKeyPackageInvitationPresentation.message(
                    accountIdHex: account, knownName: name, reason: reason
                ).lowercased()
                #expect(!message.contains("key package"))
                #expect(!message.contains("compatible"))
                #expect(!message.contains("npub"))
            }
        }
    }

    @Test func extractsRecipientOnlyFromMissingKeyPackage() {
        #expect(
            MissingKeyPackageInvitationPresentation.recipient(
                for: MarmotKitError.MissingKeyPackage(account: account, reason: .obsoleteOnly)
            ) == .init(accountIdHex: account, reason: .obsoleteOnly)
        )
        #expect(MissingKeyPackageInvitationPresentation.recipient(
            for: MarmotKitError.DirectoryLookupIncomplete(account: account)) == nil)
        #expect(MissingKeyPackageInvitationPresentation.recipient(for: MarmotKitError.Runtime(details: "offline")) == nil)
        #expect(MissingKeyPackageInvitationPresentation.recipient(for: CancellationError()) == nil)
    }
}

@MainActor
struct NewGroupMissingKeyPackageTests {
    private let peerHex = String(repeating: "c", count: 64)

    private func makeAppState(knownName: String?, defaults: UserDefaults) -> AppState {
        let appState = AppState.test()
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

    private func makeModel() -> (NewChatFlowViewModel, MemberRefFfi, NewChatFlowMarmotDouble) {
        let marmot = NewChatFlowMarmotDouble()
        let model = newChatFlow(marmot: marmot)
        let member = MemberRefFfi(memberRef: "npub1alex", accountIdHex: peerHex, npub: "npub1alex")
        model.groupSelection.add(member)
        let peerHex = peerHex
        marmot.createGroup = { _, _, _, _ in
            throw MarmotKitError.MissingKeyPackage(account: peerHex, reason: .notFound)
        }
        return (model, member, marmot)
    }

    @Test func namedMissingKeyPackageToastsAndKeepsSelectionForRetry() async throws {
        let suiteName = "MissingKeyPackage.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = makeAppState(knownName: "Alex", defaults: defaults)
        let (model, member, marmot) = makeModel()

        var opened: String?
        await model.createGroup(name: "Test", description: "", retentionSeconds: 0, using: appState) { opened = $0 }
        #expect(opened == nil)
        #expect(!model.isCreatingGroup)
        #expect(model.groupCreateError == "Alex isn't on White Noise yet.")
        #expect(appState.activeToast?.title == "Couldn't create chat")
        #expect(appState.activeToast?.message == "Alex isn't on White Noise yet.")
        #expect(model.groupSelection.memberRefs == [member.memberRef])

        marmot.createGroup = { _, _, refs, _ in
            #expect(refs == [member.memberRef])
            return "created"
        }
        await model.createGroup(name: "Test", description: "", retentionSeconds: 0, using: appState) { opened = $0 }
        #expect(opened == "created")
        #expect(model.groupCreateError == nil)
    }

    @Test func unnamedMissingKeyPackageUsesGenericCopy() async throws {
        let suiteName = "MissingKeyPackage.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = makeAppState(knownName: nil, defaults: defaults)
        let (model, member, _) = makeModel()

        await model.createGroup(name: "Test", description: "", retentionSeconds: 0, using: appState) { _ in }
        #expect(model.groupCreateError == "This user isn't on White Noise yet.")
        #expect(appState.activeToast?.title == "Couldn't create chat")
        #expect(appState.activeToast?.message == "This user isn't on White Noise yet.")
        #expect(model.groupSelection.memberRefs == [member.memberRef])
    }
}
