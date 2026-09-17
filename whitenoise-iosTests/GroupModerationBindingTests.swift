import Foundation
import Testing
import MarmotKit
@testable import whitenoise_ios

@MainActor
@Suite(.serialized)
struct GroupModerationBindingTests {
    @Test func offlineReportsRemainPendingUntilSourceAuthorizedModerationApplies() async throws {
        let client = try MarmotClient.testClient()
        let watchdog = Task {
            try await Task.sleep(for: .seconds(60))
            Issue.record("Moderation fixture exceeded its deadline")
            try await client.marmot.shutdownAndClose()
        }
        defer { watchdog.cancel() }
        do {
            try await client.startRuntime()
            let account = try await client.marmot.createIdentityWithProfile(
                defaultRelays: ["wss://relay.invalid.test"], bootstrapRelays: ["wss://relay.invalid.test"]
            ).account
            let group = try await client.createGroupWithOptionsDetailed(accountRef: account.label,
                name: "Moderation test", memberRefs: [], options: CreateGroupOptionsFfi(
                    description: nil, initialImage: nil, disappearingMessageSecs: 0))
            let live = try await client.groupConversationSnapshot(accountRef: account.label, groupIdHex: group.groupIdHex)
            #expect(live.managementState.isSelfAdmin)
            let sent = try await client.sendText(accountRef: account.label, groupIdHex: group.groupIdHex, text: "Reported text")
            let messageID = try #require(sent.messageIds.first)
            _ = try await client.reportMessage(accountRef: account.label, groupID: group.groupIdHex,
                messageID: messageID, reason: .spam, explanation: "Please review")
            let reports = try await client.contentReports(accountRef: account.label, groupID: group.groupIdHex, after: nil)
            let report = try #require(reports.reports.first)
            #expect(report.messageIdHex == messageID)
            #expect(!report.dismissed)
            let before = try #require(try await client.reportedMessage(accountRef: account.label,
                groupID: group.groupIdHex, messageID: messageID))
            #expect(before.hasReports)
            #expect(before.plaintext == "Reported text")
            let dismissal = try await client.dismissReport(accountRef: account.label, groupID: group.groupIdHex, reportID: report.reportIdHex)
            let dismissed = try await client.contentReports(accountRef: account.label, groupID: group.groupIdHex, after: nil)
            #expect(dismissal.acceptDisposition != .published)
            #expect(dismissed.reports.first?.dismissed == false)
            let preserved = try #require(try await client.reportedMessage(accountRef: account.label,
                groupID: group.groupIdHex, messageID: messageID))
            #expect(!preserved.deleted)
            #expect(preserved.plaintext == "Reported text")
            let deletion = try await client.deleteMessage(accountRef: account.label, groupIdHex: group.groupIdHex, targetMessageId: messageID)
            let removed = try #require(try await client.reportedMessage(accountRef: account.label,
                groupID: group.groupIdHex, messageID: messageID))
            #expect(deletion.acceptDisposition != .published)
            #expect(!removed.deleted)
            #expect(removed.plaintext == "Reported text")
            #expect(removed.media.isEmpty)
            let window = try await client.openConversationWindow(accountRef: account.label, groupIdHex: group.groupIdHex)
            let snapshot = try #require(window.snapshot())
            #expect(snapshot.messages.allSatisfy { ![1984, 1985, 4891].contains($0.timeline.kind) })
            #expect(snapshot.header.epoch == nil)
            #expect(!snapshot.header.capabilities.canSend)
            await window.cancel()
            try await client.marmot.shutdownAndClose()
        } catch {
            try? await client.marmot.shutdownAndClose()
            throw error
        }
    }
}
