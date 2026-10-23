import Foundation
import MarmotKit
import Testing
@testable import whitenoise_ios

@MainActor
struct NewChatFlowViewModelTests {
    @Test func finalCreateFailureKeepsSelectionAndAllowsRetry() async throws {
        let client = try MarmotClient.testClient()
        defer { try? FileManager.default.removeItem(atPath: client.rootPath) }
        let appState = AppState.test(client: client)
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

    @Test func resolvedGroupRecipientAutoSelectSkipsSelfDuplicatesAndBusyState() {
        #expect(NewChatFlowViewModel.shouldAutoSelectResolved(
            accountIdHex: "AA",
            isBusy: false,
            excludedAccountIds: [],
            selectedAccountIds: []
        ))
        #expect(!NewChatFlowViewModel.shouldAutoSelectResolved(
            accountIdHex: "AA",
            isBusy: false,
            excludedAccountIds: ["aa"],
            selectedAccountIds: []
        ))
        #expect(!NewChatFlowViewModel.shouldAutoSelectResolved(
            accountIdHex: "AA",
            isBusy: false,
            excludedAccountIds: [],
            selectedAccountIds: ["aa"]
        ))
        #expect(!NewChatFlowViewModel.shouldAutoSelectResolved(
            accountIdHex: "AA",
            isBusy: true,
            excludedAccountIds: [],
            selectedAccountIds: []
        ))
    }

    @Test func namedEmptyGroupCreationSendsSanitizedRequestWithoutMemberRefs() async throws {
        let appState = AppState.test()
        appState.activeAccountRef = "active-account"
        let model = NewChatFlowViewModel()
        var capturedAccountRef: String?
        var capturedName: String?
        var capturedMemberRefs: [String]?
        var capturedDescription: String?
        var openedGroupId: String?
        model.createGroupWithOptionsForTesting = { accountRef, name, memberRefs, options in
            capturedAccountRef = accountRef
            capturedName = name
            capturedMemberRefs = memberRefs
            capturedDescription = options.description
            return "empty-group"
        }

        await model.createGroup(
            name: "  Project North  ",
            description: "  Planning room  ",
            retentionSeconds: 0,
            using: appState,
            onOpen: { openedGroupId = $0 }
        )

        #expect(capturedAccountRef == "active-account")
        #expect(capturedName == "Project North")
        #expect(capturedMemberRefs == [])
        #expect(capturedDescription == "Planning room")
        #expect(openedGroupId == "empty-group")
    }

    @Test func newGroupCreationPassesEncryptedInitialImageInput() async throws {
        let appState = AppState.test()
        appState.activeAccountRef = "active-account"
        let model = NewChatFlowViewModel()
        let draft = GroupImageUploadDraft(
            data: Data([4, 5, 6]),
            mediaType: "image/jpeg",
            sourceURL: "https://images.example/group.jpg",
            dim: "32x16",
            thumbhash: nil
        )
        var capturedImage: InitialGroupImageFfi?
        var openedGroupId: String?
        model.createGroupWithOptionsForTesting = { _, _, _, options in
            capturedImage = options.initialImage
            return "group-with-image"
        }

        await model.createGroup(
            name: "Image Group",
            description: "",
            retentionSeconds: 0,
            image: draft,
            using: appState,
            onOpen: { openedGroupId = $0 }
        )

        #expect(capturedImage?.plaintext == draft.data)
        #expect(capturedImage?.mediaType == draft.mediaType)
        #expect(capturedImage?.sourceUrl == nil)
        #expect(openedGroupId == "group-with-image")
    }

    @Test func newGroupCreationIncludesFoundingRetentionBeforeOpening() async throws {
        let appState = AppState.test()
        appState.activeAccountRef = "active-account"
        let model = NewChatFlowViewModel()
        var events: [String] = []
        var capturedOptions: CreateGroupOptionsFfi?
        model.createGroupWithOptionsForTesting = { _, _, _, options in
            capturedOptions = options
            return "retained-group"
        }

        await model.createGroup(
            name: "Retained",
            description: "",
            retentionSeconds: 86_400,
            using: appState,
            onOpen: { groupIdHex in
                events.append("open:\(groupIdHex)")
            }
        )

        #expect(events == ["open:retained-group"])
        #expect(capturedOptions?.disappearingMessageSecs == 86_400)
    }
}
