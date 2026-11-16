import Foundation
import MarmotKit
import Testing
@testable import whitenoise_ios

@MainActor
struct NewChatFlowViewModelTests {
    @Test func finalCreateFailureKeepsSelectionAndAllowsRetry() async throws {
        let appState = AppState.test()
        appState.activeAccountRef = "account"
        let marmot = NewChatFlowMarmotDouble()
        let model = newChatFlow(marmot: marmot)
        let member = MemberRefFfi(memberRef: "npub1alice", accountIdHex: String(repeating: "a", count: 64), npub: "npub1alice")
        model.groupSelection.add(member)
        marmot.createGroup = { _, _, _, _ in
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

        marmot.createGroup = { _, _, refs, _ in
            #expect(refs == [member.memberRef])
            return "created"
        }
        await model.createGroup(name: "Test", description: "", retentionSeconds: 0, using: appState) { opened = $0 }
        #expect(opened == "created")
        #expect(model.groupCreateError == nil)
    }

    @Test func aCreateThatLeftSomeoneOutOpensTheChatAndWarnsAboutThem() async {
        let appState = AppState.test()
        appState.activeAccountRef = "account"
        let marmot = NewChatFlowMarmotDouble()
        let model = newChatFlow(marmot: marmot)
        let joined = String(repeating: "a", count: 64)
        let left = String(repeating: "b", count: 64)
        model.groupSelection.add(MemberRefFfi(memberRef: "npub1a", accountIdHex: joined, npub: "npub1a"))
        model.groupSelection.add(MemberRefFfi(memberRef: "npub1b", accountIdHex: left, npub: "npub1b"))
        marmot.createGroup = { _, _, _, _ in "created" }
        marmot.memberOutcomes = [
            MemberResolutionOutcomeFfi(accountIdHex: joined, status: .selected, selectedDeviceCount: 1),
            MemberResolutionOutcomeFfi(accountIdHex: left, status: .missingKeyPackage, selectedDeviceCount: 0),
        ]
        var opened: String?
        await model.createGroup(name: "Test", description: "", retentionSeconds: 0, using: appState) { opened = $0 }
        #expect(opened == "created")
        #expect(model.groupCreateError == nil)
        #expect(appState.activeToast?.title == "Couldn't add this person")
        #expect(appState.activeToast?.message == "This user isn't on White Noise yet.")
    }

    @Test func aCreateThatReachedNobodyStaysOnSetupWithTheReason() async {
        let appState = AppState.test()
        appState.activeAccountRef = "account"
        let marmot = NewChatFlowMarmotDouble()
        let model = newChatFlow(marmot: marmot)
        let left = String(repeating: "b", count: 64)
        let member = MemberRefFfi(memberRef: "npub1b", accountIdHex: left, npub: "npub1b")
        model.groupSelection.add(member)
        marmot.createGroup = { _, _, _, _ in nil }
        marmot.memberOutcomes = [
            MemberResolutionOutcomeFfi(accountIdHex: left, status: .missingInboxRoute, selectedDeviceCount: 0)
        ]
        var opened: String?
        await model.createGroup(name: "Test", description: "", retentionSeconds: 0, using: appState) { opened = $0 }
        #expect(opened == nil)
        #expect(model.groupCreateError == "This person’s message inbox has no relay White Noise can use.")
        #expect(appState.activeToast?.title == "Couldn't create chat")
        #expect(model.groupSelection.memberRefs == [member.memberRef])
    }

    @Test func aRetriedImageCreateWithoutAMemberReportOpensTheGroupItAlreadyMade() async {
        let appState = AppState.test()
        appState.activeAccountRef = "account"
        let marmot = NewChatFlowMarmotDouble()
        let model = newChatFlow(marmot: marmot)
        model.groupSelection.add(MemberRefFfi(memberRef: "npub1b", accountIdHex: String(repeating: "b", count: 64),
                                              npub: "npub1b"))
        var creates = 0
        marmot.createGroup = { _, _, _, _ in
            creates += 1
            throw MarmotKitError.CreatedGroupMemberReportUnavailable(groupIdHex: "earlier")
        }
        var opened: String?
        await model.createGroup(name: "Test", description: "", retentionSeconds: 0, using: appState) { opened = $0 }
        #expect(opened == "earlier")
        #expect(creates == 1)
        #expect(model.groupCreateError == nil)
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
        let marmot = NewChatFlowMarmotDouble()
        let model = newChatFlow(marmot: marmot)
        var capturedAccountRef: String?
        var capturedName: String?
        var capturedMemberRefs: [String]?
        var capturedDescription: String?
        var openedGroupId: String?
        var rowNotedBeforeOpening = false
        marmot.createGroup = { accountRef, name, memberRefs, options in
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
            onOpen: { groupIdHex in
                openedGroupId = groupIdHex
                rowNotedBeforeOpening = appState.createdChatListRow(
                    accountRef: "active-account",
                    groupIdHex: groupIdHex
                ) != nil
            }
        )

        #expect(capturedAccountRef == "active-account")
        #expect(capturedName == "Project North")
        #expect(capturedMemberRefs == [])
        #expect(capturedDescription == "Planning room")
        #expect(openedGroupId == "empty-group")
        #expect(rowNotedBeforeOpening)
    }

    @Test func existingDirectChatLookupNeedsAnActiveAccountAndOnlyReturnsReusableChats() async throws {
        let appState = AppState.test()
        var lookups: [String] = []
        let model = NewChatFlowViewModel(findExistingDirectChat: { _, accountRef, peerAccountId in
            lookups.append("\(accountRef):\(peerAccountId)")
            return existingDirectConversation(groupIdHex: "dm-\(peerAccountId)", reusable: peerAccountId == "aa")
        })

        // A cancellation would be dropped silently instead of telling the user.
        do {
            _ = try await model.existingDirectChatGroupIdHex(accountIdHex: "aa", using: appState)
            Issue.record("a lookup without an active account must fail")
        } catch {
            #expect(!(error is CancellationError))
        }
        #expect(lookups.isEmpty)

        appState.activeAccountRef = "account"
        #expect(try await model.existingDirectChatGroupIdHex(accountIdHex: "AA", using: appState) == "dm-aa")
        #expect(try await model.existingDirectChatGroupIdHex(accountIdHex: "bb", using: appState) == nil)
        #expect(lookups == ["account:aa", "account:bb"])
    }

    @Test func newGroupCreationPassesEncryptedInitialImageInput() async throws {
        let appState = AppState.test()
        appState.activeAccountRef = "active-account"
        let marmot = NewChatFlowMarmotDouble()
        let model = newChatFlow(marmot: marmot)
        let draft = GroupImageUploadDraft(
            data: Data([4, 5, 6]),
            mediaType: "image/jpeg",
            sourceURL: "https://images.example/group.jpg",
            dim: "32x16",
            thumbhash: nil
        )
        var capturedImage: InitialGroupImageFfi?
        var openedGroupId: String?
        marmot.createGroup = { _, _, _, options in
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
        let marmot = NewChatFlowMarmotDouble()
        let model = newChatFlow(marmot: marmot)
        var events: [String] = []
        var capturedOptions: CreateGroupOptionsFfi?
        marmot.createGroup = { _, _, _, options in
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
