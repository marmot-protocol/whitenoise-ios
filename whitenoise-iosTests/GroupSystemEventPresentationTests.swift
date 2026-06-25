import Foundation
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

struct GroupSystemEventPresentationTests {
    @Test func displayTextUsesJsonTextFieldWhenStructuredDataMissing() {
        let record = groupSystemRecord(
            plaintext: #"{"v":1,"system_type":"member_added","text":"Member added"}"#
        )

        #expect(
            GroupSystemEventPresentation.displayText(for: record, displayName: testDisplayName)
                == "Member added"
        )
    }

    @Test func displayTextSanitizesJsonTextFallback() {
        let record = groupSystemRecord(
            plaintext: #"{"v":1,"text":"Spoof\u202Eevil\nrow"}"#
        )

        #expect(
            GroupSystemEventPresentation.displayText(for: record, displayName: testDisplayName)
                == "Spoofevil row"
        )
    }

    @Test func displayTextResolvesAdminAddedActorAndSubject() {
        let actor = hex("aa")
        let subject = hex("bb")
        withAppLanguage(.english) {
            let text = GroupSystemEventPresentation.displayText(
                from: """
                {"v":1,"system_type":"admin_added","text":"Admin added","data":{"actor":"\(actor)","subject":"\(subject)"}}
                """,
                displayName: testDisplayName
            )

            #expect(text == "Alice made Bob an admin")
        }
    }

    @Test func displayTextUsesSenderWhenActorMissing() {
        let subject = hex("bb")
        withAppLanguage(.english) {
            let text = GroupSystemEventPresentation.displayText(
                from: """
                {"v":1,"system_type":"admin_added","text":"Admin added","data":{"subject":"\(subject)"}}
                """,
                sender: hex("aa"),
                displayName: testDisplayName
            )

            #expect(text == "Alice made Bob an admin")
        }
    }

    @Test func displayTextSanitizesGroupRenameName() {
        withAppLanguage(.english) {
            let text = GroupSystemEventPresentation.displayText(
                from: #"{"v":1,"system_type":"group_renamed","data":{"name":"Secret\u202Eevil\nClub"}}"#,
                displayName: testDisplayName
            )

            #expect(text == "Group renamed to Secretevil Club")
        }
    }

    @Test func displayTextRendersDisappearingTimerEnabled() {
        let actor = hex("aa")
        withAppLanguage(.english) {
            let text = GroupSystemEventPresentation.displayText(
                from: """
                {"v":1,"system_type":"disappearing_timer_changed","data":{"actor":"\(actor)","old_retention_seconds":0,"new_retention_seconds":60}}
                """,
                displayName: testDisplayName
            )

            #expect(text == "Alice set disappearing messages to 1 minute")
        }
    }

    @Test func displayTextRendersDisappearingTimerChanged() {
        withAppLanguage(.english) {
            let text = GroupSystemEventPresentation.displayText(
                from: """
                {"v":1,"system_type":"disappearing_timer_changed","data":{"old_retention_seconds":60,"new_retention_seconds":120}}
                """,
                displayName: testDisplayName
            )

            #expect(text == "Disappearing messages changed from 1 minute to 2 minutes")
        }
    }

    @Test func displayTextRendersDisappearingTimerDisabled() {
        let actor = hex("aa")
        withAppLanguage(.english) {
            let text = GroupSystemEventPresentation.displayText(
                from: """
                {"v":1,"system_type":"disappearing_timer_changed","data":{"actor":"\(actor)","old_retention_seconds":3600,"new_retention_seconds":0}}
                """,
                displayName: testDisplayName
            )

            #expect(text == "Alice turned off disappearing messages")
        }
    }

    @Test func displayTextFallsBackToSystemType() {
        withAppLanguage(.english) {
            let text = GroupSystemEventPresentation.displayText(
                from: #"{"v":1,"system_type":"member_removed"}"#,
                displayName: testDisplayName
            )

            #expect(text == "Member removed")
        }
    }

    @Test func displayTextSanitizesSystemTypeFallback() {
        withAppLanguage(.english) {
            let text = GroupSystemEventPresentation.displayText(
                from: #"{"v":1,"system_type":"custom_\u202Eevil\n_type"}"#,
                displayName: testDisplayName
            )

            #expect(text == "Custom evil type")
        }
    }

    @MainActor
    @Test func groupSystemTimelineRowIsVisibleWithoutStreamingDebug() throws {
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: testGroup()
        )
        let row = timelineRecord(
            messageIdHex: hex("aa"),
            plaintext: #"{"v":1,"system_type":"member_added","text":"Member added"}"#,
            kind: MessageSemantics.kindGroupSystem,
            tags: [MessageTagFfi(values: ["system", "member_added"])],
            timelineAt: 1
        )

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [row], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )

        #expect(viewModel.timeline.count == 1)
        guard case .message(let record, _) = viewModel.timeline.first?.kind else {
            Issue.record("Expected a group system message row")
            return
        }
        #expect(record.kind == MessageSemantics.kindGroupSystem)
        #expect(GroupSystemEventPresentation.isDisplayable(record))
    }

    @Test func transientGroupRenameRowsSanitizeAndUseStaticFormatKey() throws {
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewModel = try String(
            contentsOf: root.appendingPathComponent("whitenoise-ios/Conversation/ConversationViewModel.swift"),
            encoding: .utf8
        )
        let row = try String(
            contentsOf: root.appendingPathComponent("whitenoise-ios/Conversation/SystemEventRow.swift"),
            encoding: .utf8
        )

        #expect(viewModel.contains("ProfileSanitizer.groupName(record.name)"))
        #expect(!viewModel.contains("appendSystemEvent(.groupRenamed(record.name))"))
        #expect(row.contains(#"L10n.formatted("Renamed to %@", new)"#))
        #expect(!row.contains(#"L10n.string("Renamed to \(new)")"#))
    }
}

private func testDisplayName(_ accountHex: String) -> String {
    switch accountHex.prefix(2) {
    case "aa": "Alice"
    case "bb": "Bob"
    default: IdentityFormatter.short(accountHex)
    }
}

private func groupSystemRecord(plaintext: String) -> AppMessageRecordFfi {
    AppMessageRecordFfi(
        messageIdHex: hex("aa"),
        direction: "received",
        groupIdHex: hex("bb"),
        sender: hex("11"),
        plaintext: plaintext,
        contentTokens: MarkdownDocumentFfi.emptyDocument,
        kind: MessageSemantics.kindGroupSystem,
        tags: [MessageTagFfi(values: ["system", "member_added"])],
        recordedAt: 1,
        receivedAt: 1
    )
}

private func timelineRecord(
    messageIdHex: String,
    plaintext: String,
    kind: UInt64,
    tags: [MessageTagFfi],
    timelineAt: UInt64
) -> TimelineMessageRecordFfi {
    TimelineMessageRecordFfi(
        messageIdHex: messageIdHex,
        sourceMessageIdHex: nil,
        direction: "received",
        groupIdHex: hex("bb"),
        sender: hex("11"),
        plaintext: plaintext,
        contentTokens: MarkdownDocumentFfi.emptyDocument,
        kind: kind,
        tags: tags,
        timelineAt: timelineAt,
        receivedAt: timelineAt,
        replyToMessageIdHex: nil,
        replyPreview: nil,
        mediaJson: nil,
        media: [],
        agentTextStreamJson: nil,
        groupSystem: nil,
        reactions: TimelineReactionSummaryFfi(byEmoji: [], userReactions: []),
        deleted: false,
        deletedByMessageIdHex: nil,
        invalidationStatus: nil
    )
}

private func testGroup() -> AppGroupRecordFfi {
    AppGroupRecordFfi(
        groupIdHex: hex("bb"),
        endpoint: "",
        name: "Test Group",
        description: "",
        admins: [],
        relays: [],
        nostrGroupIdHex: "",
        avatarUrl: nil,
        avatarDim: nil,
        avatarThumbhash: nil,
        encryptedMedia: AppGroupEncryptedMediaComponentFfi(
            componentId: 0x8008,
            component: "marmot.group.encrypted-media.v1",
            required: true,
            mediaFormat: MessageSemantics.encryptedMediaVersion,
            allowedLocatorKinds: ["blossom-v1"],
            defaultBlobEndpoints: [
                AppBlobEndpointFfi(locatorKind: "blossom-v1", baseUrl: "https://blossom.primal.net")
            ]
        ),
        archived: false,
        pendingConfirmation: false,
        welcomerAccountIdHex: nil,
        viaWelcomeMessageIdHex: nil
    )
}

private func hex(_ byte: String) -> String {
    String(repeating: byte, count: 32)
}
