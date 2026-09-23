import Foundation
import Testing
import UserNotifications
@testable import whitenoise_ios
@testable import MarmotKit

struct NotificationPreviewStoreTests {
    @Test func absentPreferenceReadsAsTheMostPrivateMode() throws {
        let (defaults, suiteName) = try previewDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(NotificationPreviewStore.mode(defaults: defaults) == .generic)
        #expect(NotificationPreviewStore.migrationDefault == .generic)
    }

    @Test func everyModeRoundTripsThroughTheSharedSuite() throws {
        let (defaults, suiteName) = try previewDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for mode in NotificationPreviewMode.allCases {
            NotificationPreviewStore.setMode(mode, defaults: defaults)
            #expect(NotificationPreviewStore.mode(defaults: defaults) == mode)
        }
    }

    @Test func unrecognizedStoredValueFallsBackToTheMigrationDefault() throws {
        let (defaults, suiteName) = try previewDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("senderAndMessageAndEverything", forKey: NotificationPreviewStore.storageKey)

        #expect(NotificationPreviewStore.mode(defaults: defaults) == .generic)
    }

    @Test func rawValuesArePersistedAndMustNotDrift() {
        #expect(NotificationPreviewMode.senderAndMessage.rawValue == "senderAndMessage")
        #expect(NotificationPreviewMode.senderOnly.rawValue == "senderOnly")
        #expect(NotificationPreviewMode.generic.rawValue == "generic")
    }

    @Test func onlyTheFullModeRevealsContentAndOnlyGenericHidesTheSender() {
        #expect(NotificationPreviewMode.senderAndMessage.revealsMessageContent)
        #expect(!NotificationPreviewMode.senderOnly.revealsMessageContent)
        #expect(!NotificationPreviewMode.generic.revealsMessageContent)
        #expect(NotificationPreviewMode.senderAndMessage.revealsSenderIdentity)
        #expect(NotificationPreviewMode.senderOnly.revealsSenderIdentity)
        #expect(!NotificationPreviewMode.generic.revealsSenderIdentity)
    }
}

/// Foreground delivery path: `AppNotifications.present` renders exactly the
/// presentation this projection returns.
struct NotificationPreviewProjectionTests {
    @Test func senderAndMessageKeepsTheDecryptedPreview() {
        withAppLanguage(.english) {
            let dm = previewUpdate(previewText: "Ship it")
            let group = previewUpdate(isDm: false, groupName: "Project Room", previewText: "Ship it")
            let mention = previewUpdate(
                isDm: false,
                isMention: true,
                groupName: "Project Room",
                previewText: "Ship it"
            )

            #expect(presentation(dm, .senderAndMessage)?.title == "Alice")
            #expect(presentation(dm, .senderAndMessage)?.body == "Ship it")
            #expect(presentation(group, .senderAndMessage)?.body == "Alice: Ship it")
            #expect(presentation(mention, .senderAndMessage)?.body == "Alice mentioned you: Ship it")
        }
    }

    @Test func senderOnlyNamesTheSenderWithoutTheMessage() {
        withAppLanguage(.english) {
            let dm = presentation(previewUpdate(previewText: "Ship it"), .senderOnly)
            let group = presentation(
                previewUpdate(isDm: false, groupName: "Project Room", previewText: "Ship it"),
                .senderOnly
            )
            let mention = presentation(
                previewUpdate(isDm: false, isMention: true, groupName: "Project Room", previewText: "Ship it"),
                .senderOnly
            )

            #expect(dm?.title == "Alice")
            #expect(dm?.body == "New encrypted message")
            #expect(group?.title == "Project Room")
            #expect(group?.body == "Alice sent a message")
            #expect(mention?.body == "Alice mentioned you")
            for rendered in [dm, group, mention] {
                #expect(!containsPlaintext(rendered, "Ship it"))
                // The sender survives so iOS can still draw the avatar.
                #expect(rendered?.senderName == "Alice")
            }
        }
    }

    @Test func genericRevealsNeitherSenderNorMessage() {
        withAppLanguage(.english) {
            let dm = presentation(previewUpdate(previewText: "Ship it"), .generic)
            let group = presentation(
                previewUpdate(isDm: false, groupName: "Project Room", previewText: "Ship it"),
                .generic
            )

            for rendered in [dm, group] {
                #expect(rendered?.title == "White Noise")
                #expect(rendered?.body == "New encrypted message")
                #expect(!containsPlaintext(rendered, "Ship it"))
                #expect(!containsPlaintext(rendered, "Alice"))
                #expect(!containsPlaintext(rendered, "Project Room"))
                #expect(rendered?.senderName == nil)
                #expect(rendered?.senderAccountIdHex == nil)
                #expect(rendered?.senderPictureUrl == nil)
                #expect(rendered?.isGroupConversation == false)
            }
        }
    }

    @Test func genericWithholdsGroupStateNoticesAndInviteDetails() {
        withAppLanguage(.english) {
            for trigger in [
                NotificationTriggerFfi.groupInvite,
                .removedFromGroup,
                .madeAdmin,
                .removedAsAdmin,
            ] {
                let update = previewUpdate(
                    trigger: trigger,
                    isDm: false,
                    groupName: "Project Room",
                    previewText: nil
                )

                let generic = presentation(update, .generic)
                #expect(generic?.title == "White Noise")
                #expect(generic?.body == "New encrypted message")
                #expect(!containsPlaintext(generic, "Project Room"))
                // Sender-only withholds message text, not membership notices.
                #expect(presentation(update, .senderOnly) == presentation(update, .senderAndMessage))
            }
        }
    }

    @Test func routingAndActionsSurviveEveryMode() {
        let update = previewUpdate(previewText: "Ship it")

        for mode in NotificationPreviewMode.allCases {
            let rendered = presentation(update, mode)
            #expect(rendered?.route.groupIdHex == "group-a")
            #expect(rendered?.identifier == presentation(update, .senderAndMessage)?.identifier)
            #expect(rendered?.threadIdentifier == "conv-a")
            #expect(rendered?.categoryIdentifier == NotificationActionCategory.message)
        }
    }

    @Test func pictureUrlEgressIsDroppedOnlyForGeneric() {
        let update = previewUpdate(pictureUrl: "https://example.com/avatar.png")

        #expect(presentation(update, .senderAndMessage)?.senderPictureUrl == "https://example.com/avatar.png")
        #expect(presentation(update, .senderOnly)?.senderPictureUrl == "https://example.com/avatar.png")
        #expect(presentation(update, .generic)?.senderPictureUrl == nil)
    }

    /// Sender-only makes the name the entire payload, so the private nickname
    /// has to keep winning over the peer-controlled kind:0 name there — and a
    /// nickname is more sensitive than a public name, so generic must withhold
    /// it too.
    @Test func nicknamesOutrankPublicNamesInEveryModeThatShowsAName() {
        withAppLanguage(.english) {
            let update = previewUpdate(previewText: "Ship it")
            let owner = String(repeating: "11", count: 32)
            let sender = String(repeating: "22", count: 32)
            let nickname: (String, String) -> String? = { resolvedOwner, contact in
                resolvedOwner == owner && contact == sender ? "Bestie" : nil
            }

            for mode in [NotificationPreviewMode.senderAndMessage, .senderOnly] {
                let rendered = LocalNotificationProjection.makePresentation(
                    for: update,
                    nickname: nickname,
                    previewMode: mode
                )
                #expect(rendered?.title == "Bestie")
                #expect(rendered?.senderName == "Bestie")
                #expect(!containsPlaintext(rendered, "Alice"))
            }

            let group = LocalNotificationProjection.makePresentation(
                for: previewUpdate(isDm: false, groupName: "Project Room", previewText: "Ship it"),
                nickname: nickname,
                previewMode: .senderOnly
            )
            #expect(group?.body == "Bestie sent a message")

            let generic = LocalNotificationProjection.makePresentation(
                for: update,
                nickname: nickname,
                previewMode: .generic
            )
            #expect(!containsPlaintext(generic, "Bestie"))
            #expect(!containsPlaintext(generic, "Alice"))
            #expect(generic?.senderName == nil)
        }
    }

    private func presentation(
        _ update: NotificationUpdateFfi,
        _ mode: NotificationPreviewMode
    ) -> LocalNotificationPresentation? {
        LocalNotificationProjection.makePresentation(for: update, previewMode: mode)
    }
}

/// Notification Service Extension path: the decision the extension applies to
/// the alert that woke it, plus the extra presentations it enqueues itself.
struct NotificationPreviewServiceDecisionTests {
    @Test func everyModeRedactsThePrimaryAndAdditionalPresentations() {
        withAppLanguage(.english) {
            let collection = BackgroundNotificationCollectionFfi(
                status: .newData,
                notifications: [
                    previewUpdate(notificationKey: "newest", previewText: "Ship it", timestampMs: 3_000),
                    previewUpdate(
                        notificationKey: "older",
                        groupIdHex: "group-b",
                        previewText: "Second secret",
                        timestampMs: 2_000
                    ),
                ],
                error: nil
            )
            let expectations: [NotificationPreviewMode: (title: String, body: String)] = [
                .senderAndMessage: ("Alice", "Ship it"),
                .senderOnly: ("Alice", "New encrypted message"),
                .generic: ("White Noise", "New encrypted message"),
            ]

            for (mode, expected) in expectations {
                let decision = NotificationServiceProjection.decision(for: collection, previewMode: mode)
                guard case .decorate(let primary, let additional) = decision else {
                    Issue.record("expected a decorated decision for \(mode)")
                    continue
                }

                #expect(primary.title == expected.title)
                #expect(primary.body == expected.body)
                #expect(additional.count == 1)
                for rendered in [primary] + additional {
                    #expect(mode.revealsMessageContent || !containsPlaintext(rendered, "Ship it"))
                    #expect(mode.revealsMessageContent || !containsPlaintext(rendered, "Second secret"))
                    #expect(mode.revealsSenderIdentity || !containsPlaintext(rendered, "Alice"))
                    #expect(mode.revealsSenderIdentity || rendered.senderName == nil)
                }
            }
        }
    }

    @Test func overflowSummariesStayGenericInEveryMode() {
        let updates = (0..<20).map { index in
            previewUpdate(
                notificationKey: "key-\(index)",
                previewText: "Secret \(index)",
                timestampMs: Int64(1_000 + index)
            )
        }

        for mode in NotificationPreviewMode.allCases where !mode.revealsMessageContent {
            let presentations = NotificationPresentationPolicy.boundedAdditionalPresentations(
                from: updates,
                previewMode: mode
            )

            #expect(!presentations.isEmpty)
            for rendered in presentations {
                for index in 0..<20 {
                    #expect(!containsPlaintext(rendered, "Secret \(index)"))
                }
            }
        }
    }

    @Test func nicknamesReachTheExtensionsPresentationsInSenderOnlyMode() {
        withAppLanguage(.english) {
            let owner = String(repeating: "11", count: 32)
            let sender = String(repeating: "22", count: 32)
            let collection = BackgroundNotificationCollectionFfi(
                status: .newData,
                notifications: [
                    previewUpdate(notificationKey: "newest", previewText: "Ship it", timestampMs: 3_000),
                    previewUpdate(notificationKey: "older", groupIdHex: "group-b", previewText: "Later", timestampMs: 2_000),
                ],
                error: nil
            )

            let decision = NotificationServiceProjection.decision(
                for: collection,
                nickname: { resolvedOwner, contact in
                    resolvedOwner == owner && contact == sender ? "Bestie" : nil
                },
                previewMode: .senderOnly
            )

            guard case .decorate(let primary, let additional) = decision else {
                Issue.record("expected a decorated decision")
                return
            }
            #expect(primary.title == "Bestie")
            for rendered in [primary] + additional {
                #expect(rendered.senderName == "Bestie")
                #expect(!containsPlaintext(rendered, "Alice"))
            }
        }
    }

    @Test func perChatNotifyModeStillFiltersUnderEveryPreviewMode() {
        let collection = BackgroundNotificationCollectionFfi(
            status: .newData,
            notifications: [previewUpdate(previewText: "Ship it")],
            error: nil
        )

        for mode in NotificationPreviewMode.allCases {
            // A non-mention record in a mentions-only chat stays suppressed,
            // and a fully suppressed wake still delivers quietly.
            #expect(NotificationServiceProjection.decision(
                for: collection,
                notifyMode: { _, _ in .mentionsOnly },
                previewMode: mode
            ) == .deliverQuietly)
            #expect(NotificationServiceProjection.decision(
                for: collection,
                notifyMode: { _, _ in .nothing },
                previewMode: mode
            ) == .deliverQuietly)

            let all = NotificationServiceProjection.decision(
                for: collection,
                notifyMode: { _, _ in .all },
                previewMode: mode
            )
            if case .decorate = all {} else {
                Issue.record("expected \(mode) to decorate an unmuted chat")
            }
        }
    }
}

/// Communication-intent metadata is decorated from the presentation, so the
/// redaction has to hold at that boundary too.
struct NotificationPreviewCommunicationIntentTests {
    @Test func senderOnlyDonatesNoMessageTextToTheIntent() throws {
        let presentation = try #require(withAppLanguage(.english) {
            LocalNotificationProjection.makePresentation(
                for: previewUpdate(previewText: "Ship it"),
                previewMode: .senderOnly
            )
        })
        let content = NotificationContentDecorator.makeContent(for: presentation)

        let decorated = NotificationCommunicationDecorator.decorated(
            content,
            presentation: presentation,
            avatarData: nil
        )

        // `INSendMessageIntent.content` is the presentation body, so a withheld
        // preview cannot reach the intent.
        #expect(decorated.body == "New encrypted message")
        #expect(!decorated.body.contains("Ship it"))
        #expect(!decorated.title.contains("Ship it"))
        #expect(decorated.subtitle.isEmpty)
    }

    @Test func genericIsNeverDecoratedAsACommunicationNotification() throws {
        let presentation = try #require(withAppLanguage(.english) {
            LocalNotificationProjection.makePresentation(
                for: previewUpdate(previewText: "Ship it", pictureUrl: "https://example.com/avatar.png"),
                previewMode: .generic
            )
        })
        let content = NotificationContentDecorator.makeContent(for: presentation)

        let decorated = NotificationCommunicationDecorator.decorated(
            content,
            presentation: presentation,
            avatarData: nil
        )

        // No sender name means the decorator hands back the very same content:
        // no INPerson, no avatar, and no intent `content` are donated.
        #expect(decorated === content)
        #expect(decorated.title == "White Noise")
        #expect(decorated.body == "New encrypted message")
        #expect(decorated.subtitle.isEmpty)
    }
}

@MainActor
struct NotificationPreviewSettingsViewModelTests {
    @Test func modelStartsFromStorageAndPersistsSelections() throws {
        let (defaults, suiteName) = try previewDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        NotificationPreviewStore.setMode(.senderOnly, defaults: defaults)

        let model = NotificationSettingsViewModel(previewDefaults: defaults)
        #expect(model.previewMode == .senderOnly)

        model.setPreviewMode(.senderAndMessage)
        #expect(model.previewMode == .senderAndMessage)
        #expect(NotificationPreviewStore.mode(defaults: defaults) == .senderAndMessage)
    }

    @Test func anUnresolvableSuiteKeepsShowingTheModeStillInForce() {
        let model = NotificationSettingsViewModel(previewDefaults: nil)

        model.setPreviewMode(.senderAndMessage)

        #expect(model.previewMode == .generic)
    }
}

/// The Settings picker promises a wording; the projection delivers one. They
/// are only the same string if the example is built from the shipped keys.
struct NotificationPreviewExampleTests {
    private static let shippedLanguages: [AppLanguage] = [
        .english, .german, .spanish, .french, .italian,
        .portuguese, .russian, .turkish, .chineseSimplified, .chineseTraditional,
    ]

    @Test func everyExampleIsTheBodyTheNotificationActuallyDelivers() {
        for language in Self.shippedLanguages {
            withAppLanguage(language) {
                let update = previewUpdate(
                    isDm: false,
                    groupName: "Project Room",
                    senderName: L10n.string("Mom"),
                    previewText: L10n.string("Good morning!")
                )

                for mode in NotificationPreviewMode.allCases {
                    let delivered = LocalNotificationProjection.makePresentation(
                        for: update,
                        previewMode: mode
                    )?.body
                    #expect(
                        mode.example == delivered,
                        "\(language.rawValue)/\(mode.rawValue): settings shows \(mode.example), notification delivers \(delivered ?? "nil")"
                    )
                }
            }
        }
    }

    @Test func senderOnlyExampleNamesTheSenderAndWithholdsTheMessage() {
        for language in Self.shippedLanguages {
            withAppLanguage(language) {
                let example = NotificationPreviewMode.senderOnly.example

                #expect(example.contains(L10n.string("Mom")))
                #expect(!example.contains(L10n.string("Good morning!")))
                #expect(example != NotificationPreviewMode.generic.example)
            }
        }
    }

    @Test func genericExampleIsTheExtensionsFallbackBodyVerbatim() {
        for language in Self.shippedLanguages {
            withAppLanguage(language) {
                #expect(
                    NotificationPreviewMode.generic.example
                        == LocalNotificationProjection.genericContentText().body
                )
            }
        }
    }
}

private func previewDefaults() throws -> (UserDefaults, String) {
    // The shared App Group suite is visible to every concurrently running test
    // suite and to the extension, so each test gets its own domain.
    let suiteName = "dev.ipf.whitenoise.ios.tests.notification-preview.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}

private func containsPlaintext(_ presentation: LocalNotificationPresentation?, _ text: String) -> Bool {
    guard let presentation else { return false }
    return [presentation.title, presentation.body, presentation.senderName ?? ""]
        .contains { $0.localizedStandardContains(text) }
}

private func previewUpdate(
    notificationKey: String = "key-a",
    trigger: NotificationTriggerFfi = .newMessage,
    groupIdHex: String = "group-a",
    isDm: Bool = true,
    isMention: Bool = false,
    groupName: String? = nil,
    senderName: String? = "Alice",
    previewText: String? = "Hello",
    pictureUrl: String? = nil,
    timestampMs: Int64 = 1_700_000_000_123
) -> NotificationUpdateFfi {
    NotificationUpdateFfi(
        notificationKey: notificationKey,
        conversationKey: "conv-a",
        trigger: trigger,
        accountRef: "account-a",
        accountIdHex: String(repeating: "11", count: 32),
        groupIdHex: groupIdHex,
        groupName: groupName,
        isDm: isDm,
        isMention: isMention,
        messageIdHex: "message-\(notificationKey)",
        sender: NotificationUserFfi(
            accountIdHex: String(repeating: "22", count: 32),
            displayName: senderName,
            pictureUrl: pictureUrl
        ),
        receiver: NotificationUserFfi(
            accountIdHex: String(repeating: "11", count: 32),
            displayName: "Me",
            pictureUrl: nil
        ),
        previewText: previewText,
        reactionEmoji: nil,
        reactedToPreview: nil,
        timestampMs: timestampMs,
        isFromSelf: false
    )
}
