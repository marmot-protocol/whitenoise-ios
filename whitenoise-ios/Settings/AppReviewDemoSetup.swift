import Foundation
import MarmotKit
import Observation

struct AppReviewDemoCheckpoint: Codable, Equatable {
    let originalAccountRef: String
    let originalAccountIdHex: String
    let initialAccountRefs: [String]
    var johnnyAccountRef: String?
    var johnnyAccountIdHex: String?
    var johnnyProfilePublished = false
    var groupIdHex: String?
    var completed = false
}

@MainActor
struct AppReviewDemoCheckpointStore {
    static let storageKey = "appReview.demoCheckpoint.v1"

    let defaults: UserDefaults

    func load() -> AppReviewDemoCheckpoint? {
        guard let data = defaults.data(forKey: Self.storageKey) else { return nil }
        return try? JSONDecoder().decode(AppReviewDemoCheckpoint.self, from: data)
    }

    func save(_ checkpoint: AppReviewDemoCheckpoint) throws {
        defaults.set(try JSONEncoder().encode(checkpoint), forKey: Self.storageKey)
    }

    func clear() {
        defaults.removeObject(forKey: Self.storageKey)
    }
}

@MainActor
@Observable
final class AppReviewDemoCoordinator {
    enum Stage: Equatable {
        case preparing
        case creatingJohnny
        case publishingJohnnyProfile
        case waitingForJohnny
        case creatingConversation
        case sendingFirstMessages
        case acceptingInvitation
        case sendingJohnnyMessages
        case addingRepliesAndReactions
        case returningToOriginalProfile

        var title: String {
            switch self {
            case .preparing: L10n.string("Preparing the demo")
            case .creatingJohnny: L10n.string("Creating Johnny Appleseed")
            case .publishingJohnnyProfile: L10n.string("Publishing Johnny’s profile")
            case .waitingForJohnny: L10n.string("Finishing Johnny’s secure setup")
            case .creatingConversation: L10n.string("Creating the encrypted conversation")
            case .sendingFirstMessages: L10n.string("Sending the first messages")
            case .acceptingInvitation: L10n.string("Accepting the invitation as Johnny")
            case .sendingJohnnyMessages: L10n.string("Sending messages as Johnny")
            case .addingRepliesAndReactions: L10n.string("Adding replies and reactions")
            case .returningToOriginalProfile: L10n.string("Returning to the original profile")
            }
        }
    }

    enum Status: Equatable {
        case idle
        case running(Stage)
        case failed(String)
        case ready(groupIdHex: String, accountRef: String)
    }

    private enum DemoError: LocalizedError {
        case unavailable
        case originalProfileMissing
        case demoProfileMissing
        case ambiguousCreatedProfile
        case setupRecoveryRequired
        case setupTimedOut
        case invitationTimedOut
        case messageTimedOut

        var errorDescription: String? {
            switch self {
            case .unavailable:
                L10n.string("The demo can only be created while the app is connected and a local profile is active.")
            case .originalProfileMissing:
                L10n.string("The original profile is no longer available. Clear the saved demo setup and try again.")
            case .demoProfileMissing:
                L10n.string("Johnny’s saved demo profile is no longer available. Clear the saved demo setup and try again.")
            case .ambiguousCreatedProfile:
                L10n.string("The demo profile could not be identified safely. Clear the saved demo setup and try again.")
            case .setupRecoveryRequired:
                L10n.string("A profile needs account-setup recovery before the demo can continue.")
            case .setupTimedOut:
                L10n.string("Secure profile setup is taking longer than expected. Check the connection and resume setup.")
            case .invitationTimedOut:
                L10n.string("Johnny has not received the conversation yet. Check the connection and resume setup.")
            case .messageTimedOut:
                L10n.string("The demo messages are still being delivered. Check the connection and resume setup.")
            }
        }
    }

    private enum Copy {
        static let originalGreeting = "Hi Johnny! Welcome to White Noise. 👋"
        static let originalPrivacy = "This is a real end-to-end encrypted conversation created for App Review."
        static let johnnyReply = "Hi! I received the invitation and can read your messages."
        static let johnnyFeature = "Replies and reactions work across both profiles on this device."
        static let originalReply = "Great — the review demo is ready to explore."
    }

    private(set) var status: Status = .idle
    private(set) var hasSavedSetup = false

    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    @ObservationIgnored private weak var appState: AppState?
    @ObservationIgnored private var checkpointStore: AppReviewDemoCheckpointStore?
    @ObservationIgnored private var task: Task<Void, Never>?

    func configure(appState: AppState, defaults: UserDefaults) {
        self.appState = appState
        checkpointStore = AppReviewDemoCheckpointStore(defaults: defaults)
        let checkpoint = checkpointStore?.load()
        hasSavedSetup = checkpoint != nil
        if let checkpoint, checkpoint.completed,
           let groupIdHex = checkpoint.groupIdHex {
            status = .ready(groupIdHex: groupIdHex, accountRef: checkpoint.originalAccountRef)
        }
    }

    func startOrOpen() {
        guard task == nil else { return }
        if case .ready(let groupIdHex, let accountRef) = status {
            appState?.presentChat(groupIdHex: groupIdHex, accountRef: accountRef)
            return
        }

        task = Task { @MainActor [weak self] in
            guard let self else { return }
            await run()
            task = nil
        }
    }

    func clearSavedSetup() {
        guard !isRunning else { return }
        checkpointStore?.clear()
        hasSavedSetup = false
        status = .idle
    }

    private func run() async {
        guard let appState,
              appState.canUseRuntimeForForegroundWork,
              let active = appState.activeAccount,
              active.localSigning,
              !active.signedOut,
              let checkpointStore
        else {
            status = .failed(DemoError.unavailable.localizedDescription)
            return
        }

        var checkpoint = checkpointStore.load() ?? AppReviewDemoCheckpoint(
            originalAccountRef: active.label,
            originalAccountIdHex: active.accountIdHex,
            initialAccountRefs: appState.accounts.map(\.label)
        )
        do {
            try checkpointStore.save(checkpoint)
            hasSavedSetup = true
            status = .running(.preparing)

            guard appState.accounts.contains(where: {
                $0.label == checkpoint.originalAccountRef && !$0.signedOut
            }) else {
                throw DemoError.originalProfileMissing
            }

            if checkpoint.johnnyAccountRef == nil {
                try await waitForTrackedSetupIfNeeded(
                    accountRef: checkpoint.originalAccountRef,
                    appState: appState
                )
            }

            let johnny = try await ensureJohnny(
                checkpoint: &checkpoint,
                appState: appState,
                store: checkpointStore
            )
            try Task.checkCancellation()

            status = .running(.waitingForJohnny)
            try await waitForNetworkReadiness(accountRef: johnny.label, appState: appState)
            try await ensureJohnnyProfile(
                johnny,
                checkpoint: &checkpoint,
                appState: appState,
                store: checkpointStore
            )
            await appState.completeSecondaryIdentityProfileSetup(johnny)
            try Task.checkCancellation()

            status = .running(.creatingConversation)
            await appState.activateAccount(checkpoint.originalAccountRef)
            guard appState.activeAccountRef == checkpoint.originalAccountRef else {
                throw DemoError.originalProfileMissing
            }
            let groupIdHex = try await ensureConversation(
                checkpoint: &checkpoint,
                johnny: johnny,
                appState: appState,
                store: checkpointStore
            )
            let client = try appState.currentMarmotClient()

            status = .running(.sendingFirstMessages)
            _ = try await ensureMessage(
                text: Copy.originalGreeting,
                senderAccountIdHex: checkpoint.originalAccountIdHex,
                accountRef: checkpoint.originalAccountRef,
                groupIdHex: groupIdHex,
                client: client
            )
            _ = try await ensureMessage(
                text: Copy.originalPrivacy,
                senderAccountIdHex: checkpoint.originalAccountIdHex,
                accountRef: checkpoint.originalAccountRef,
                groupIdHex: groupIdHex,
                client: client
            )

            status = .running(.acceptingInvitation)
            try await deliverConversation(
                accountRef: johnny.label,
                groupIdHex: groupIdHex,
                client: client
            )
            await appState.activateAccount(johnny.label)
            guard appState.activeAccountRef == johnny.label else { throw DemoError.unavailable }
            try await acceptInvitationIfNeeded(
                accountRef: johnny.label,
                groupIdHex: groupIdHex,
                client: client
            )
            let johnnyGreetingTarget = try await waitForMessage(
                text: Copy.originalGreeting,
                senderAccountIdHex: checkpoint.originalAccountIdHex,
                accountRef: johnny.label,
                groupIdHex: groupIdHex,
                client: client
            )

            status = .running(.sendingJohnnyMessages)
            let johnnyReply = try await ensureReply(
                text: Copy.johnnyReply,
                targetMessageIdHex: johnnyGreetingTarget.messageIdHex,
                senderAccountIdHex: johnny.accountIdHex,
                accountRef: johnny.label,
                groupIdHex: groupIdHex,
                client: client
            )
            let johnnyFeature = try await ensureMessage(
                text: Copy.johnnyFeature,
                senderAccountIdHex: johnny.accountIdHex,
                accountRef: johnny.label,
                groupIdHex: groupIdHex,
                client: client
            )
            try await ensureReaction(
                emoji: "👍",
                senderAccountIdHex: johnny.accountIdHex,
                targetMessageIdHex: johnnyGreetingTarget.messageIdHex,
                accountRef: johnny.label,
                groupIdHex: groupIdHex,
                client: client
            )

            status = .running(.addingRepliesAndReactions)
            await appState.activateAccount(checkpoint.originalAccountRef)
            guard appState.activeAccountRef == checkpoint.originalAccountRef else {
                throw DemoError.originalProfileMissing
            }
            try await deliverMessages(
                [johnnyReply.messageIdHex, johnnyFeature.messageIdHex],
                accountRef: checkpoint.originalAccountRef,
                groupIdHex: groupIdHex,
                client: client
            )
            try await waitForReaction(
                emoji: "👍",
                senderAccountIdHex: johnny.accountIdHex,
                targetMessageIdHex: johnnyGreetingTarget.messageIdHex,
                accountRef: checkpoint.originalAccountRef,
                groupIdHex: groupIdHex,
                client: client
            )
            let originalTarget = try await waitForMessage(
                text: Copy.johnnyFeature,
                senderAccountIdHex: johnny.accountIdHex,
                accountRef: checkpoint.originalAccountRef,
                groupIdHex: groupIdHex,
                client: client
            )
            _ = try await ensureReply(
                text: Copy.originalReply,
                targetMessageIdHex: originalTarget.messageIdHex,
                senderAccountIdHex: checkpoint.originalAccountIdHex,
                accountRef: checkpoint.originalAccountRef,
                groupIdHex: groupIdHex,
                client: client
            )
            try await ensureReaction(
                emoji: "❤️",
                senderAccountIdHex: checkpoint.originalAccountIdHex,
                targetMessageIdHex: johnnyReply.messageIdHex,
                accountRef: checkpoint.originalAccountRef,
                groupIdHex: groupIdHex,
                client: client
            )

            status = .running(.returningToOriginalProfile)
            checkpoint.completed = true
            try checkpointStore.save(checkpoint)
            hasSavedSetup = true
            appState.noteDirectChatPeer(
                accountRef: checkpoint.originalAccountRef,
                groupIdHex: groupIdHex,
                peerAccountIdHex: johnny.accountIdHex
            )
            appState.presentChat(
                groupIdHex: groupIdHex,
                accountRef: checkpoint.originalAccountRef
            )
            status = .ready(groupIdHex: groupIdHex, accountRef: checkpoint.originalAccountRef)
            Haptics.success()
        } catch is CancellationError {
            status = .failed(L10n.string("Demo setup was interrupted. Resume it when the app is active."))
        } catch {
            let failedStage: Stage?
            if case .running(let stage) = status {
                failedStage = stage
            } else {
                failedStage = nil
            }
            if appState.activeAccountRef != checkpoint.originalAccountRef {
                await appState.activateAccount(checkpoint.originalAccountRef)
            }
            let message = UserFacingError.message(
                for: error,
                fallbackMessage: L10n.string("The demo could not be completed. Check the connection and resume setup.")
            )
            status = .failed(failedStage.map { "\($0.title): \(message)" } ?? message)
            Haptics.error()
        }
    }

    private func ensureJohnny(
        checkpoint: inout AppReviewDemoCheckpoint,
        appState: AppState,
        store: AppReviewDemoCheckpointStore
    ) async throws -> AccountSummaryFfi {
        let client = try appState.currentMarmotClient()
        let accounts = try await client.listAccounts()
        let johnny: AccountSummaryFfi

        if let johnnyAccountRef = checkpoint.johnnyAccountRef {
            guard let existing = accounts.first(where: { $0.label == johnnyAccountRef }) else {
                throw DemoError.demoProfileMissing
            }
            johnny = existing
        } else {
            let candidates = accounts.filter { !checkpoint.initialAccountRefs.contains($0.label) }
            if candidates.count == 1, let existing = candidates.first {
                johnny = existing
            } else if candidates.isEmpty {
                status = .running(.creatingJohnny)
                let creation = try await createJohnnyWhenReady(appState: appState)
                johnny = creation.account
            } else {
                throw DemoError.ambiguousCreatedProfile
            }
            checkpoint.johnnyAccountRef = johnny.label
            checkpoint.johnnyAccountIdHex = johnny.accountIdHex
            try store.save(checkpoint)
        }

        guard checkpoint.johnnyAccountIdHex == nil
                || checkpoint.johnnyAccountIdHex == johnny.accountIdHex
        else { throw DemoError.ambiguousCreatedProfile }
        checkpoint.johnnyAccountIdHex = johnny.accountIdHex

        return johnny
    }

    private func createJohnnyWhenReady(appState: AppState) async throws -> IdentityCreationResultFfi {
        for attempt in 0..<120 {
            try Task.checkCancellation()
            do {
                return try await appState.createIdentityForProfileSetup()
            } catch MarmotKitError.AccountSetupRetryRequired {
                if attempt == 119 { throw MarmotKitError.AccountSetupRetryRequired }
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        throw DemoError.setupTimedOut
    }

    private func ensureJohnnyProfile(
        _ johnny: AccountSummaryFfi,
        checkpoint: inout AppReviewDemoCheckpoint,
        appState: AppState,
        store: AppReviewDemoCheckpointStore
    ) async throws {
        if !checkpoint.johnnyProfilePublished {
            status = .running(.publishingJohnnyProfile)
            let client = try appState.currentMarmotClient()
            let existing = try await client.userProfileForEditing(accountIdHex: johnny.accountIdHex)
            let profile = UserProfileMetadataFfi(
                name: "Johnny Appleseed",
                displayName: "Johnny Appleseed",
                about: "App Review demo profile",
                picture: existing?.picture,
                banner: existing?.banner,
                nip05: existing?.nip05,
                lud16: existing?.lud16
            )
            try await appState.publishOnboardingProfile(accountRef: johnny.label, profile: profile)
            checkpoint.johnnyProfilePublished = true
            try store.save(checkpoint)
        }
    }

    private func waitForNetworkReadiness(accountRef: String, appState: AppState) async throws {
        let client = try appState.currentMarmotClient()
        for _ in 0..<120 {
            try Task.checkCancellation()
            switch try await client.accountSetupReadiness(accountRef: accountRef) {
            case .networkReady:
                return
            case .recoveryRequired:
                throw DemoError.setupRecoveryRequired
            case .initializing, .localReady, .publishing:
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        throw DemoError.setupTimedOut
    }

    private func waitForTrackedSetupIfNeeded(accountRef: String, appState: AppState) async throws {
        let client = try appState.currentMarmotClient()
        let readiness: AccountSetupReadinessFfi
        do {
            readiness = try await client.accountSetupReadiness(accountRef: accountRef)
        } catch {
            // Imported identities do not necessarily have generated-account
            // setup state. Creation itself remains the authoritative gate.
            return
        }
        switch readiness {
        case .networkReady:
            return
        case .recoveryRequired:
            throw DemoError.setupRecoveryRequired
        case .initializing, .localReady, .publishing:
            try await waitForNetworkReadiness(accountRef: accountRef, appState: appState)
        }
    }

    private func ensureConversation(
        checkpoint: inout AppReviewDemoCheckpoint,
        johnny: AccountSummaryFfi,
        appState: AppState,
        store: AppReviewDemoCheckpointStore
    ) async throws -> String {
        let client = try appState.currentMarmotClient()
        if let groupIdHex = checkpoint.groupIdHex { return groupIdHex }
        if let existing = try await client.existingDirectConversation(
            accountRef: checkpoint.originalAccountRef,
            peerAccountId: johnny.accountIdHex
        ), existing.reusable {
            checkpoint.groupIdHex = existing.groupIdHex
            try store.save(checkpoint)
            return existing.groupIdHex
        }

        let member = try await client.normalizeMemberRef(memberRef: johnny.accountIdHex)
        _ = try await client.prewarmGroupMemberKeyPackages(
            accountRef: checkpoint.originalAccountRef,
            memberRefs: [member.memberRef]
        )

        do {
            let created = try await client.createGroupWithOptionsDetailed(
                accountRef: checkpoint.originalAccountRef,
                name: "",
                memberRefs: [member.memberRef],
                options: CreateGroupOptionsFfi(
                    description: nil,
                    initialImage: nil,
                    disappearingMessageSecs: 0
                )
            )
            checkpoint.groupIdHex = created.groupIdHex
            try store.save(checkpoint)
            appState.noteCreatedChatListRow(
                accountRef: checkpoint.originalAccountRef,
                row: created.chatListRow
            )
            appState.noteDirectChatPeer(
                accountRef: checkpoint.originalAccountRef,
                groupIdHex: created.groupIdHex,
                peerAccountIdHex: johnny.accountIdHex
            )
            return created.groupIdHex
        } catch {
            if let existing = try await client.existingDirectConversation(
                accountRef: checkpoint.originalAccountRef,
                peerAccountId: johnny.accountIdHex
            ), existing.reusable {
                checkpoint.groupIdHex = existing.groupIdHex
                try store.save(checkpoint)
                return existing.groupIdHex
            }
            throw error
        }
    }

    private func deliverConversation(
        accountRef: String,
        groupIdHex: String,
        client: MarmotClient
    ) async throws {
        for _ in 0..<60 {
            try Task.checkCancellation()
            try await catchUpForDemo(client: client)
            if try await client.chatListRow(accountRef: accountRef, groupIdHex: groupIdHex) != nil {
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw DemoError.invitationTimedOut
    }

    private func acceptInvitationIfNeeded(
        accountRef: String,
        groupIdHex: String,
        client: MarmotClient
    ) async throws {
        for attempt in 0..<8 {
            try Task.checkCancellation()
            guard let row = try await client.chatListRow(
                accountRef: accountRef,
                groupIdHex: groupIdHex
            ) else {
                try await catchUpForDemo(client: client)
                try await Task.sleep(for: .milliseconds(500))
                continue
            }
            if !row.pendingConfirmation { return }
            do {
                _ = try await client.acceptGroupInvite(
                    accountRef: accountRef,
                    groupIdHex: groupIdHex
                )
                return
            } catch let error as MarmotKitError where error.isAccountWorkerBusy
                    || error.isAccountWorkerResponseTimedOut {
                if attempt == 7 { throw error }
                try await Task.sleep(for: .milliseconds(500))
            } catch MarmotKitError.GroupInviteNotPending {
                return
            }
        }
        throw DemoError.invitationTimedOut
    }

    private func ensureMessage(
        text: String,
        senderAccountIdHex: String,
        accountRef: String,
        groupIdHex: String,
        client: MarmotClient
    ) async throws -> TimelineMessageRecordFfi {
        if let existing = try await findMessage(
            text: text,
            senderAccountIdHex: senderAccountIdHex,
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            client: client
        ) {
            return existing
        }
        _ = try await client.sendText(accountRef: accountRef, groupIdHex: groupIdHex, text: text)
        return try await waitForMessage(
            text: text,
            senderAccountIdHex: senderAccountIdHex,
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            client: client
        )
    }

    private func ensureReply(
        text: String,
        targetMessageIdHex: String,
        senderAccountIdHex: String,
        accountRef: String,
        groupIdHex: String,
        client: MarmotClient
    ) async throws -> TimelineMessageRecordFfi {
        if let existing = try await findMessage(
            text: text,
            senderAccountIdHex: senderAccountIdHex,
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            client: client
        ), existing.replyToMessageIdHex == targetMessageIdHex {
            return existing
        }
        _ = try await client.replyToMessage(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            targetMessageId: targetMessageIdHex,
            text: text
        )
        return try await waitForMessage(
            text: text,
            senderAccountIdHex: senderAccountIdHex,
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            client: client
        )
    }

    private func ensureReaction(
        emoji: String,
        senderAccountIdHex: String,
        targetMessageIdHex: String,
        accountRef: String,
        groupIdHex: String,
        client: MarmotClient
    ) async throws {
        if try await hasReaction(
            emoji: emoji,
            senderAccountIdHex: senderAccountIdHex,
            targetMessageIdHex: targetMessageIdHex,
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            client: client
        ) { return }
        _ = try await client.reactToMessage(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            targetMessageId: targetMessageIdHex,
            emoji: emoji
        )
        for _ in 0..<20 {
            try Task.checkCancellation()
            if try await hasReaction(
                emoji: emoji,
                senderAccountIdHex: senderAccountIdHex,
                targetMessageIdHex: targetMessageIdHex,
                accountRef: accountRef,
                groupIdHex: groupIdHex,
                client: client
            ) {
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw DemoError.messageTimedOut
    }

    private func deliverMessages(
        _ messageIds: [String],
        accountRef: String,
        groupIdHex: String,
        client: MarmotClient
    ) async throws {
        let expected = Set(messageIds.filter { !$0.isEmpty })
        for _ in 0..<60 {
            try Task.checkCancellation()
            try await catchUpForDemo(client: client)
            let page = try await timeline(accountRef: accountRef, groupIdHex: groupIdHex, client: client)
            if expected.isSubset(of: Set(page.messages.map(\.messageIdHex))) { return }
            try await Task.sleep(for: .seconds(1))
        }
        throw DemoError.messageTimedOut
    }

    private func waitForReaction(
        emoji: String,
        senderAccountIdHex: String,
        targetMessageIdHex: String,
        accountRef: String,
        groupIdHex: String,
        client: MarmotClient
    ) async throws {
        for _ in 0..<60 {
            try Task.checkCancellation()
            try await catchUpForDemo(client: client)
            if try await hasReaction(
                emoji: emoji,
                senderAccountIdHex: senderAccountIdHex,
                targetMessageIdHex: targetMessageIdHex,
                accountRef: accountRef,
                groupIdHex: groupIdHex,
                client: client
            ) {
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw DemoError.messageTimedOut
    }

    private func waitForMessage(
        text: String,
        senderAccountIdHex: String,
        accountRef: String,
        groupIdHex: String,
        client: MarmotClient
    ) async throws -> TimelineMessageRecordFfi {
        for _ in 0..<60 {
            try Task.checkCancellation()
            try await catchUpForDemo(client: client)
            if let message = try await findMessage(
                text: text,
                senderAccountIdHex: senderAccountIdHex,
                accountRef: accountRef,
                groupIdHex: groupIdHex,
                client: client
            ) {
                return message
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw DemoError.messageTimedOut
    }

    private func findMessage(
        text: String,
        senderAccountIdHex: String,
        accountRef: String,
        groupIdHex: String,
        client: MarmotClient
    ) async throws -> TimelineMessageRecordFfi? {
        let page = try await timeline(accountRef: accountRef, groupIdHex: groupIdHex, client: client)
        return page.messages.last {
            $0.kind == MessageSemantics.kindChat
                && !$0.deleted
                && $0.sender.caseInsensitiveCompare(senderAccountIdHex) == .orderedSame
                && $0.plaintext == text
        }
    }

    private func hasReaction(
        emoji: String,
        senderAccountIdHex: String,
        targetMessageIdHex: String,
        accountRef: String,
        groupIdHex: String,
        client: MarmotClient
    ) async throws -> Bool {
        let page = try await timeline(accountRef: accountRef, groupIdHex: groupIdHex, client: client)
        guard let target = page.messages.first(where: { $0.messageIdHex == targetMessageIdHex }) else {
            return false
        }
        return target.reactions.userReactions.contains {
            $0.emoji == emoji
                && $0.sender.caseInsensitiveCompare(senderAccountIdHex) == .orderedSame
        }
    }

    private func timeline(
        accountRef: String,
        groupIdHex: String,
        client: MarmotClient
    ) async throws -> TimelinePageFfi {
        try await client.timelineMessages(
            accountRef: accountRef,
            query: TimelineMessageQueryFfi(
                groupIdHex: groupIdHex,
                search: nil,
                before: nil,
                beforeMessageId: nil,
                after: nil,
                afterMessageId: nil,
                limit: 100
            )
        )
    }

    private func catchUpForDemo(client: MarmotClient) async throws {
        do {
            try await client.catchUpAccounts()
        } catch let error as MarmotKitError where error.isAccountWorkerBusy
                || error.isAccountWorkerResponseTimedOut {
            // Account switches schedule their own foreground maintenance. Let
            // that in-flight work finish, then inspect the projection again.
        }
    }
}
