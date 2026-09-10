import Foundation
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

struct GroupSystemEventPresentationTests {
    @Test func structuredBindingProjectionAvoidsJsonFallbackAndNamesCurrentAccountAsYou() {
        let me = hex("aa")
        let other = hex("bb")
        let record = groupSystemRecord(plaintext: "not json", sender: me)
        let projection = GroupSystemEventFfi(
            systemType: "member_added",
            text: "Member added",
            actorAccountIdHex: me,
            subjectAccountIdHex: other,
            name: nil,
            oldName: nil,
            oldRetentionSeconds: nil,
            newRetentionSeconds: nil
        )

        let text = GroupSystemEventPresentation.displayText(
            for: record,
            groupSystem: projection,
            currentAccountIdHex: me,
            displayName: testDisplayName
        )

        #expect(text == "You added Bob")
        #expect(GroupSystemEventPresentation.isDisplayable(record, groupSystem: projection))
    }

    @Test func structuredBindingProjectionUsesActorForGroupIdentityChanges() {
        let actor = hex("aa")
        let renamed = GroupSystemEventFfi(
            systemType: "group_renamed",
            text: "Group renamed",
            actorAccountIdHex: actor,
            subjectAccountIdHex: nil,
            name: "Weekend Walks",
            oldName: "Walks",
            oldRetentionSeconds: nil,
            newRetentionSeconds: nil
        )

        let text = GroupSystemEventPresentation.displayText(
            for: groupSystemRecord(plaintext: "not json", sender: actor),
            groupSystem: renamed,
            displayName: testDisplayName
        )

        #expect(text == "Alice changed the group name to Weekend Walks")
    }

    @Test func oversizedPayloadIsRejectedBeforeParsing() {
        // Same ceiling as the agent-event parser: the cap must run before
        // JSONSerialization materializes an attacker-sized payload. The
        // oversized record renders exactly like an unparseable one.
        let padding = String(repeating: "a", count: MessagePreview.timelineMediaPreviewMaxJsonBytes)
        let oversized = "{\"v\":1,\"system_type\":\"member_added\",\"text\":\"" + padding + "\"}"

        let display = GroupSystemEventPresentation.displayText(
            for: groupSystemRecord(plaintext: oversized),
            displayName: testDisplayName
        )
        let unparseableBaseline = GroupSystemEventPresentation.displayText(
            for: groupSystemRecord(plaintext: "not json"),
            displayName: testDisplayName
        )

        #expect(display == unparseableBaseline)
        #expect(display?.contains(padding) != true)
    }

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

    @Test func displayTextIgnoresNonHexActorAndSubject() {
        withAppLanguage(.english) {
            let text = GroupSystemEventPresentation.displayText(
                from: #"{"v":1,"system_type":"admin_added","text":"Admin added","data":{"actor":"alice\u202E","subject":"bob\u200D"}}"#,
                displayName: testDisplayName
            )

            #expect(text == "Admin added")
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

    @Test func adminRowsUseDedicatedSentencesWhenTheSubjectIsTheSignedInAccount() {
        let me = hex("cc")
        withAppLanguage(.english) {
            #expect(
                systemDisplayText(systemType: "admin_added", subject: me, currentAccountIdHex: me)
                    == "You were made an admin"
            )
            #expect(
                systemDisplayText(
                    systemType: "admin_added",
                    actor: hex("aa"),
                    subject: me,
                    currentAccountIdHex: me
                ) == "Alice made you an admin"
            )
            #expect(
                systemDisplayText(
                    systemType: "admin_added",
                    actor: me,
                    subject: hex("bb"),
                    currentAccountIdHex: me
                ) == "You made Bob an admin"
            )
            #expect(
                systemDisplayText(
                    systemType: "admin_added",
                    actor: hex("aa"),
                    subject: hex("bb"),
                    currentAccountIdHex: me
                ) == "Alice made Bob an admin"
            )
            #expect(
                systemDisplayText(systemType: "admin_removed", subject: me, currentAccountIdHex: me)
                    == "You are no longer an admin"
            )
            #expect(
                systemDisplayText(
                    systemType: "admin_removed",
                    actor: hex("aa"),
                    subject: me,
                    currentAccountIdHex: me
                ) == "Alice removed you as admin"
            )
            #expect(
                systemDisplayText(
                    systemType: "admin_removed",
                    actor: me,
                    subject: hex("bb"),
                    currentAccountIdHex: me
                ) == "You removed Bob as admin"
            )
        }
    }

    @Test func membershipRowsUseDedicatedSentencesWhenTheSubjectIsTheSignedInAccount() {
        let me = hex("cc")
        withAppLanguage(.english) {
            #expect(
                systemDisplayText(systemType: "member_added", subject: me, currentAccountIdHex: me)
                    == "You were added"
            )
            #expect(
                systemDisplayText(
                    systemType: "member_added",
                    actor: hex("aa"),
                    subject: me,
                    currentAccountIdHex: me
                ) == "Alice added you"
            )
            #expect(
                systemDisplayText(systemType: "member_removed", subject: me, currentAccountIdHex: me)
                    == "You were removed"
            )
            #expect(
                systemDisplayText(
                    systemType: "member_removed",
                    actor: hex("aa"),
                    subject: me,
                    currentAccountIdHex: me
                ) == "Alice removed you"
            )
            #expect(
                systemDisplayText(
                    systemType: "member_removed",
                    actor: me,
                    subject: hex("bb"),
                    currentAccountIdHex: me
                ) == "You removed Bob"
            )
            #expect(
                systemDisplayText(systemType: "member_left", actor: me, currentAccountIdHex: me)
                    == "You left"
            )
            #expect(
                systemDisplayText(systemType: "member_left", actor: hex("aa"), currentAccountIdHex: me)
                    == "Alice left"
            )
            #expect(
                systemDisplayText(systemType: "member_left", subject: me, currentAccountIdHex: me)
                    == "You left"
            )
        }
    }

    @Test func groupMetadataRowsUseDedicatedSentencesWhenTheActorIsTheSignedInAccount() {
        let me = hex("cc")
        withAppLanguage(.english) {
            #expect(
                systemDisplayText(
                    systemType: "group_renamed",
                    actor: me,
                    name: "Weekend Walks",
                    currentAccountIdHex: me
                ) == "You changed the group name to Weekend Walks"
            )
            #expect(
                systemDisplayText(systemType: "group_renamed", actor: me, currentAccountIdHex: me)
                    == "Group renamed"
            )
            #expect(
                systemDisplayText(systemType: "group_avatar_changed", actor: me, currentAccountIdHex: me)
                    == "You changed the group photo"
            )
            #expect(
                systemDisplayText(
                    systemType: "disappearing_timer_changed",
                    actor: me,
                    oldRetentionSeconds: 3_600,
                    newRetentionSeconds: 0,
                    currentAccountIdHex: me
                ) == "You turned off disappearing messages"
            )
            #expect(
                systemDisplayText(
                    systemType: "disappearing_timer_changed",
                    actor: me,
                    oldRetentionSeconds: 0,
                    newRetentionSeconds: 60,
                    currentAccountIdHex: me
                ) == "You set disappearing messages to 1 minute"
            )
            #expect(
                systemDisplayText(
                    systemType: "disappearing_timer_changed",
                    actor: me,
                    oldRetentionSeconds: 60,
                    newRetentionSeconds: 120,
                    currentAccountIdHex: me
                ) == "You changed disappearing messages from 1 minute to 2 minutes"
            )
        }
    }

    @Test func selfAndOtherAdminRowsInflectSeparatelyPerLocale() {
        let me = hex("cc")
        let other = hex("bb")
        withAppLanguage(.spanish) {
            #expect(
                systemDisplayText(systemType: "admin_added", subject: me, currentAccountIdHex: me)
                    == "Te nombraron administrador"
            )
            #expect(
                systemDisplayText(systemType: "admin_added", subject: other, currentAccountIdHex: me)
                    == "Nombraron administrador a Bob"
            )
            #expect(
                systemDisplayText(
                    systemType: "admin_added",
                    actor: me,
                    subject: other,
                    currentAccountIdHex: me
                ) == "Hiciste administrador a Bob"
            )
            #expect(
                systemDisplayText(
                    systemType: "admin_added",
                    actor: other,
                    subject: me,
                    currentAccountIdHex: me
                ) == "Bob te hizo administrador"
            )
        }
        withAppLanguage(.german) {
            #expect(
                systemDisplayText(systemType: "admin_added", subject: me, currentAccountIdHex: me)
                    == "Du wurdest zum Administrator gemacht"
            )
            #expect(
                systemDisplayText(systemType: "admin_added", subject: other, currentAccountIdHex: me)
                    == "Bob wurde zum Administrator gemacht"
            )
        }
        withAppLanguage(.portuguese) {
            #expect(
                systemDisplayText(systemType: "admin_added", subject: me, currentAccountIdHex: me)
                    == "Você agora é administrador"
            )
            #expect(
                systemDisplayText(systemType: "admin_added", subject: other, currentAccountIdHex: me)
                    == "Bob agora é administrador"
            )
        }
        withAppLanguage(.italian) {
            #expect(
                systemDisplayText(systemType: "admin_added", subject: me, currentAccountIdHex: me)
                    == "Ora sei amministratore"
            )
            #expect(
                systemDisplayText(systemType: "admin_added", subject: other, currentAccountIdHex: me)
                    == "Bob ora è amministratore"
            )
        }
    }

    @Test func recordPreviewsNameTheSignedInReaderAndFallBackToTheSender() {
        let me = hex("cc")
        let actor = hex("aa")
        let naming = GroupSystemEventNaming(currentAccountIdHex: me, displayName: testDisplayName)

        withAppLanguage(.english) {
            #expect(
                MessagePreview.body(
                    groupSystemRecord(
                        plaintext: """
                        {"v":1,"system_type":"member_added","text":"Member added",\
                        "data":{"actor":"\(actor)","subject":"\(me)"}}
                        """,
                        sender: actor
                    ),
                    systemEventNaming: naming
                ) == "Alice added you"
            )
            #expect(
                MessagePreview.body(
                    groupSystemRecord(
                        plaintext: """
                        {"v":1,"system_type":"member_added","text":"Member added",\
                        "data":{"subject":"\(me)"}}
                        """,
                        sender: actor
                    ),
                    systemEventNaming: naming
                ) == "Alice added you"
            )
        }
    }

    @Test func replyPreviewsNameTheSignedInReader() {
        let me = hex("cc")
        let actor = hex("aa")
        let preview = TimelineReplyPreviewFfi(
            messageIdHex: hex("dd"),
            sender: actor,
            plaintext: """
            {"v":1,"system_type":"member_added","text":"Member added",\
            "data":{"actor":"\(actor)","subject":"\(me)"}}
            """,
            kind: MessageSemantics.kindGroupSystem,
            mediaJson: nil,
            agentTextStreamJson: nil,
            deleted: false
        )

        withAppLanguage(.english) {
            #expect(
                MessagePreview.body(
                    preview,
                    systemEventNaming: GroupSystemEventNaming(
                        currentAccountIdHex: me,
                        displayName: testDisplayName
                    )
                ) == "Alice added you"
            )
            #expect(MessagePreview.body(preview) == "npub1424…amrcaj added npub1enx…n2pktz")
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
            plaintext: "not json",
            kind: MessageSemantics.kindGroupSystem,
            tags: [MessageTagFfi(values: ["system", "member_added"])],
            timelineAt: 1,
            groupSystem: GroupSystemEventFfi(
                systemType: "member_added",
                text: "Member added",
                actorAccountIdHex: nil,
                subjectAccountIdHex: nil,
                name: nil,
                oldName: nil,
                oldRetentionSeconds: nil,
                newRetentionSeconds: nil
            )
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
        #expect(viewModel.groupSystemDisplayText(for: record) == "Member added")
    }

    @MainActor
    @Test func groupSystemTimelineDisplayTextIsCachedPerProjectionGeneration() throws {
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
        let record = try #require(viewModel.record(for: row.messageIdHex))

        #expect(viewModel.groupSystemDisplayText(for: record) == "Member added")
        #expect(viewModel.groupSystemDisplayText(for: record) == "Member added")
        #expect(viewModel.groupSystemProjectionBuildCountForTesting == 1)

        let projectionGeneration = viewModel.timelineProjectionGeneration
        viewModel.refreshProfileDependentTimelineProjections()

        #expect(viewModel.timelineProjectionGeneration == projectionGeneration + 1)
        #expect(viewModel.groupSystemDisplayText(for: record) == "Member added")
        #expect(viewModel.groupSystemProjectionBuildCountForTesting == 2)
    }
}

private func systemDisplayText(
    systemType: String,
    actor: String? = nil,
    subject: String? = nil,
    name: String? = nil,
    oldRetentionSeconds: UInt64? = nil,
    newRetentionSeconds: UInt64? = nil,
    currentAccountIdHex: String? = nil
) -> String? {
    GroupSystemEventPresentation.displayText(
        for: groupSystemRecord(plaintext: "not json", sender: ""),
        groupSystem: GroupSystemEventFfi(
            systemType: systemType,
            text: "System event",
            actorAccountIdHex: actor,
            subjectAccountIdHex: subject,
            name: name,
            oldName: nil,
            oldRetentionSeconds: oldRetentionSeconds,
            newRetentionSeconds: newRetentionSeconds
        ),
        currentAccountIdHex: currentAccountIdHex,
        displayName: testDisplayName
    )
}

private func testDisplayName(_ accountHex: String) -> String {
    switch accountHex.prefix(2) {
    case "aa": "Alice"
    case "bb": "Bob"
    default: IdentityFormatter.short(accountHex)
    }
}

private func groupSystemRecord(plaintext: String, sender: String = hex("11")) -> AppMessageRecordFfi {
    AppMessageRecordFfi(
        messageIdHex: hex("aa"),
        direction: "received",
        groupIdHex: hex("bb"),
        sender: sender,
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
    timelineAt: UInt64,
    groupSystem: GroupSystemEventFfi? = nil
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
        groupSystem: groupSystem,
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
            mediaFormat: EncryptedMediaVersionFfi.v1.wireValue,
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
