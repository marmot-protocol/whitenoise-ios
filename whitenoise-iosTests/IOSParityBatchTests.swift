import Foundation
import Testing
@testable import MarmotKit
@testable import whitenoise_ios

@MainActor
struct IOSParityBatchTests {
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

    @Test func namedGroupsCanBeCreatedWithoutInvitees() {
        #expect(AddMembersPresentation.canCreate(
            stagedCount: 0,
            hasUsableName: true,
            isCreating: false,
            hasActiveAccount: true
        ))
        #expect(!AddMembersPresentation.canCreate(
            stagedCount: 0,
            hasUsableName: false,
            isCreating: false,
            hasActiveAccount: true
        ))
        #expect(AddMembersPresentation.canCreate(
            stagedCount: 1,
            hasUsableName: false,
            isCreating: false,
            hasActiveAccount: true
        ))
        #expect(!AddMembersPresentation.canInvite(stagedCount: 0, isInviting: false))
    }

    @Test func namedEmptyGroupCreationSendsSanitizedRequestWithoutMemberRefs() async throws {
        let appState = AppState(client: try MarmotClient.testClient())
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
        let appState = AppState(client: try MarmotClient.testClient())
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
        let appState = AppState(client: try MarmotClient.testClient())
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

    @Test func emptyGroupInviteRequiresConfirmedSoleMemberAdmin() {
        #expect(EmptyGroupConversationPresentation.canInvite(
            isSelfMember: true,
            isSelfAdmin: true,
            membersLoaded: true,
            memberCount: 1,
            onlyMemberIsSelf: true
        ))
        #expect(!EmptyGroupConversationPresentation.canInvite(
            isSelfMember: true,
            isSelfAdmin: true,
            membersLoaded: false,
            memberCount: 0,
            onlyMemberIsSelf: false
        ))
        #expect(!EmptyGroupConversationPresentation.canInvite(
            isSelfMember: true,
            isSelfAdmin: false,
            membersLoaded: true,
            memberCount: 1,
            onlyMemberIsSelf: true
        ))
    }

    @Test func quickReactionChoicesAreStableUniqueAndFilledToSix() {
        #expect(QuickReactionChoices.normalize(["🔥", "🔥", "\u{202E}", "👍"]) == [
            "🔥", "👍", "❤️", "👎", "😂", "😮",
        ])
        #expect(QuickReactionChoices.normalize(["❤", "❤️"]).filter { $0 == "❤" || $0 == "❤️" }.count == 1)
    }

    @Test func choosingAnExistingQuickReactionSwapsOnlyTheTwoSlots() {
        let choices = ["❤️", "👍", "👎", "😂", "😮", "😢"]

        #expect(QuickReactionChoices.replacing(choices, at: 0, with: "😂") == [
            "😂", "👍", "👎", "❤️", "😮", "😢",
        ])
        #expect(QuickReactionChoices.replacing(choices, at: 1, with: "🔥") == [
            "❤️", "🔥", "👎", "😂", "😮", "😢",
        ])
    }

    @Test func customizedQuickReactionsPersistAndOverrideRecents() throws {
        let suiteName = "IOSParityBatchTests.quickReactions.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(QuickReactionChoices.resolved(
            customized: nil,
            recent: ["🔥"]
        ) == ["🔥", "❤️", "👍", "👎", "😂", "😮"])

        let saved = QuickReactionPreferences.save(
            ["🚀", "✅", "🎉", "👀", "🙏", "💯"],
            to: defaults
        )
        let reloaded = QuickReactionPreferences.load(from: defaults)

        #expect(reloaded == saved)
        #expect(QuickReactionChoices.resolved(
            customized: reloaded,
            recent: ["🔥", "😢"]
        ) == saved)

        let reset = QuickReactionPreferences.save(AppState.defaultReactions, to: defaults)
        #expect(QuickReactionPreferences.load(from: defaults) == AppState.defaultReactions)
        #expect(QuickReactionChoices.resolved(
            customized: reset,
            recent: ["🔥"]
        ) == AppState.defaultReactions)
    }

    @Test func activeRetentionReplacesMemberSubtitleButConnectingWins() {
        #expect(ConversationHeaderSecondary.resolve(
            isRuntimeWarmingUp: false,
            subtitle: "4 members",
            retentionSeconds: 300
        ) == .retention(300))
        #expect(ConversationHeaderSecondary.resolve(
            isRuntimeWarmingUp: true,
            subtitle: "4 members",
            retentionSeconds: 300
        ) == .connecting)
    }

    @Test func mediaLocatorStaticValidationAllowsOnlyPublicHttpsBlossom() {
        #expect(EncryptedMediaLocatorValidation.isStaticallySafe([
            locator("https://media.example/blob"),
        ]))
        #expect(!EncryptedMediaLocatorValidation.isStaticallySafe([
            locator("http://media.example/blob"),
        ]))
        #expect(!EncryptedMediaLocatorValidation.isStaticallySafe([
            locator("https://user:password@media.example/blob"),
        ]))
        #expect(!EncryptedMediaLocatorValidation.isStaticallySafe([
            locator("https://media.example:8443/blob"),
        ]))
        #expect(!EncryptedMediaLocatorValidation.isStaticallySafe([
            locator("not a url"),
        ]))
        #expect(!EncryptedMediaLocatorValidation.isStaticallySafe([
            locator("https://127.0.0.1/blob"),
        ]))
        #expect(!EncryptedMediaLocatorValidation.isStaticallySafe([
            locator("https://service.localhost/blob"),
        ]))
        #expect(!EncryptedMediaLocatorValidation.isStaticallySafe([
            locator("https://media.example/blob"),
            locator("https://10.0.0.5/private"),
        ]))
        #expect(EncryptedMediaLocatorValidation.isStaticallySafe([
            MediaLocatorFfi(kind: "ipfs-v1", value: "https://10.0.0.5/private"),
            locator("https://media.example/blob"),
        ]))
        #expect(!EncryptedMediaLocatorValidation.isStaticallySafe([
            MediaLocatorFfi(kind: "ipfs-v1", value: "https://media.example/blob"),
        ]))
    }

    @Test func mediaLocatorResolutionFailsClosedOnPrivateOrMissingDns() {
        let locators = [locator("https://media.example/blob")]
        #expect(EncryptedMediaLocatorValidation.resolvesOnlyToPublicAddresses(locators) { _ in
            ["93.184.216.34"]
        })
        #expect(!EncryptedMediaLocatorValidation.resolvesOnlyToPublicAddresses(locators) { _ in
            ["10.0.0.5"]
        })
        #expect(!EncryptedMediaLocatorValidation.resolvesOnlyToPublicAddresses(locators) { _ in
            []
        })
    }

    @Test func optimisticImetaParserRejectsUnsafeLocator() {
        let values = [
            MessageSemantics.imetaTag,
            "v \(EncryptedMediaVersionFfi.v1.wireValue)",
            "locator blossom-v1 https://192.168.1.1/\(String(repeating: "a", count: 64)).bin",
            "ciphertext_sha256 \(String(repeating: "a", count: 64))",
            "plaintext_sha256 \(String(repeating: "b", count: 64))",
            "nonce \(String(repeating: "c", count: 24))",
            "m image/jpeg",
            "filename photo.jpg",
        ]
        #expect(MessageSemantics.mediaAttachments(from: [MessageTagFfi(values: values)]) == nil)
    }

    @Test func optimisticImetaParserRetainsUnsupportedLocatorWithSafeBlossomFallback() throws {
        let values = [
            MessageSemantics.imetaTag,
            "v \(EncryptedMediaVersionFfi.v1.wireValue)",
            "locator ipfs-v1 ipfs://bafy-test",
            "locator blossom-v1 https://media.example/\(String(repeating: "a", count: 64)).bin",
            "ciphertext_sha256 \(String(repeating: "a", count: 64))",
            "plaintext_sha256 \(String(repeating: "b", count: 64))",
            "nonce \(String(repeating: "c", count: 24))",
            "m image/jpeg",
            "filename photo.jpg",
        ]

        let attachment = try #require(MessageSemantics.mediaAttachments(
            from: [MessageTagFfi(values: values)]
        )?.first)
        #expect(attachment.locators.map(\.kind) == ["ipfs-v1", "blossom-v1"])
    }

    @Test func optimisticImetaParserKeepsValidSiblingWhenMdkRejectsMalformedTag() throws {
        let valid = MessageTagFfi(values: [
            MessageSemantics.imetaTag,
            "v \(EncryptedMediaVersionFfi.v1.wireValue)",
            "locator blossom-v1 https://media.example/\(String(repeating: "a", count: 64)).bin",
            "ciphertext_sha256 \(String(repeating: "a", count: 64))",
            "plaintext_sha256 \(String(repeating: "b", count: 64))",
            "nonce \(String(repeating: "c", count: 24))",
            "m image/jpeg",
            "filename photo.jpg",
        ])
        let malformed = MessageTagFfi(values: [
            MessageSemantics.imetaTag,
            "v unknown-version",
        ])

        let attachment = try #require(MessageSemantics.mediaAttachments(
            from: [malformed, valid],
            sourceEpoch: 42
        )?.first)
        #expect(attachment.fileName == "photo.jpg")
        #expect(attachment.sourceEpoch == 42)
    }

    private func locator(_ value: String) -> MediaLocatorFfi {
        MediaLocatorFfi(kind: EncryptedMediaLocatorValidation.blossomKind, value: value)
    }
}
