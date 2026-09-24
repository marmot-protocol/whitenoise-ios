import Foundation
import Testing
@testable import whitenoise_ios

struct ChatMuteActionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func durationsProduceAbsoluteDeadlines() {
        #expect(ChatMuteDuration.oneHour.deadline(from: now) == now.addingTimeInterval(3600))
        #expect(ChatMuteDuration.eightHours.deadline(from: now) == now.addingTimeInterval(28800))
        #expect(ChatMuteDuration.oneDay.deadline(from: now) == now.addingTimeInterval(86400))
        #expect(ChatMuteDuration.oneWeek.deadline(from: now) == now.addingTimeInterval(604800))
        #expect(ChatMuteDuration.always.deadline(from: now) == nil)
    }

    @Test func timedMutePersistsAndExpiresWithoutAnotherWrite() throws {
        try withDefaults { defaults in
            ChatMuteAction.mute(.oneHour).perform(accountIdHex: "aa", groupIdHex: "01", defaults: defaults, now: now)
            let snapshot = ChatMuteStore.notifyModeSnapshot(defaults: defaults)
            let deadline = now.addingTimeInterval(3_600)
            #expect(mode(snapshot, at: now) == .nothing)
            #expect(mode(snapshot, at: deadline.addingTimeInterval(-0.001)) == .nothing)
            #expect(mode(snapshot, at: deadline) == .all)
            #expect(ChatMuteStore.muteExpiry(accountIdHex: "aa", groupIdHex: "01", in: snapshot, now: now) == deadline)
            #expect(ChatMuteStore.muteExpiry(accountIdHex: "aa", groupIdHex: "01", in: snapshot, now: deadline) == nil)
            let key = try #require(ChatMuteStore.key(accountIdHex: "aa", groupIdHex: "01"))
            #expect(ChatMuteStore.mutedChatKeys(defaults: defaults, now: now) == [key])
            #expect(ChatMuteStore.mutedChatKeys(defaults: defaults, now: deadline).isEmpty)
        }
    }

    @Test func timedReplacementPreservesOtherAccountsAndChats() throws {
        try withDefaults { defaults in
            for (account, group) in [("aa", "01"), ("aa", "02"), ("bb", "01")] {
                ChatMuteStore.setNotifyMode(.nothing, accountIdHex: account, groupIdHex: group, defaults: defaults)
            }
            ChatMuteAction.mute(.oneHour).perform(accountIdHex: "aa", groupIdHex: "01", defaults: defaults, now: now)
            let snapshot = ChatMuteStore.notifyModeSnapshot(defaults: defaults)
            let afterExpiry = now.addingTimeInterval(3_600)
            #expect(mode(snapshot, at: afterExpiry) == .all)
            #expect(ChatMuteStore.notifyMode(accountIdHex: "aa", groupIdHex: "02", in: snapshot, now: afterExpiry) == .nothing)
            #expect(ChatMuteStore.notifyMode(accountIdHex: "bb", groupIdHex: "01", in: snapshot, now: afterExpiry) == .nothing)
        }
    }

    @Test func extendingTimedMutePreservesMentionsOnlyAfterExpiry() throws {
        try withDefaults { defaults in
            ChatMuteStore.setNotifyMode(.mentionsOnly, accountIdHex: "aa", groupIdHex: "01", defaults: defaults)
            ChatMuteAction.mute(.oneHour).perform(accountIdHex: "aa", groupIdHex: "01", defaults: defaults, now: now)
            ChatMuteAction.mute(.eightHours).perform(accountIdHex: "aa", groupIdHex: "01", defaults: defaults, now: now)
            let snapshot = ChatMuteStore.notifyModeSnapshot(defaults: defaults)
            #expect(mode(snapshot, at: now.addingTimeInterval(3_600)) == .nothing)
            #expect(mode(snapshot, at: now.addingTimeInterval(28_800)) == .mentionsOnly)
        }
    }

    @Test func explicitModeReplacesTimedMute() throws {
        try withDefaults { defaults in
            for newMode in ChatNotifyMode.allCases {
                ChatMuteAction.mute(.oneHour).perform(accountIdHex: "aa", groupIdHex: "01", defaults: defaults, now: now)
                ChatMuteStore.setNotifyMode(newMode, accountIdHex: "aa", groupIdHex: "01", defaults: defaults)
                let snapshot = ChatMuteStore.notifyModeSnapshot(defaults: defaults)
                #expect(mode(snapshot, at: now) == newMode)
                #expect(mode(snapshot, at: now.addingTimeInterval(3_600)) == newMode)
                #expect(ChatMuteStore.muteExpiry(accountIdHex: "aa", groupIdHex: "01", in: snapshot, now: now) == nil)
            }
        }
    }

    @Test func alwaysAndUnmuteReplaceTimedMute() throws {
        try withDefaults { defaults in
            ChatMuteAction.mute(.oneHour).perform(accountIdHex: "aa", groupIdHex: "01", defaults: defaults, now: now)
            ChatMuteAction.mute(.always).perform(accountIdHex: "aa", groupIdHex: "01", defaults: defaults, now: now)
            #expect(mode(ChatMuteStore.notifyModeSnapshot(defaults: defaults), at: now.addingTimeInterval(86_400)) == .nothing)
            ChatMuteAction.unmute.perform(accountIdHex: "aa", groupIdHex: "01", defaults: defaults, now: now)
            #expect(mode(ChatMuteStore.notifyModeSnapshot(defaults: defaults), at: now) == .all)
            #expect(ChatMuteStore.mutedChatKeys(defaults: defaults, now: now).isEmpty)
        }
    }

    @Test func clearingAccountRemovesItsDeadlinesAndKeepsOtherAccounts() throws {
        try withDefaults { defaults in
            ChatMuteAction.mute(.oneHour).perform(accountIdHex: "aa", groupIdHex: "01", defaults: defaults, now: now)
            ChatMuteAction.mute(.oneDay).perform(accountIdHex: "bb", groupIdHex: "01", defaults: defaults, now: now)
            ChatMuteStore.clearAll(accountIdHex: "AA", defaults: defaults)
            let snapshot = ChatMuteStore.notifyModeSnapshot(defaults: defaults)
            #expect(mode(snapshot, at: now) == .all)
            #expect(ChatMuteStore.nextMuteExpiry(accountIdHex: "aa", in: snapshot, now: now) == nil)
            #expect(ChatMuteStore.nextMuteExpiry(accountIdHex: "bb", in: snapshot, now: now) == now.addingTimeInterval(86_400))
            #expect(ChatMuteStore.notifyMode(accountIdHex: "bb", groupIdHex: "01", in: snapshot, now: now) == .nothing)
        }
    }

    @Test func nextExpirySkipsExpiredAndForeignDeadlines() throws {
        try withDefaults { defaults in
            for (account, group, duration) in [("aa", "01", ChatMuteDuration.oneHour), ("aa", "02", .oneDay), ("bb", "01", .eightHours)] {
                ChatMuteAction.mute(duration).perform(accountIdHex: account, groupIdHex: group, defaults: defaults, now: now)
            }
            let snapshot = ChatMuteStore.notifyModeSnapshot(defaults: defaults)
            #expect(ChatMuteStore.nextMuteExpiry(accountIdHex: " AA ", in: snapshot, now: now) == now.addingTimeInterval(3_600))
            #expect(ChatMuteStore.nextMuteExpiry(accountIdHex: "aa", in: snapshot, now: now.addingTimeInterval(3_600)) == now.addingTimeInterval(86_400))
        }
    }

    private func mode(_ snapshot: ChatMuteStore.NotifyModeSnapshot, at date: Date) -> ChatNotifyMode {
        ChatMuteStore.notifyMode(accountIdHex: "aa", groupIdHex: "01", in: snapshot, now: date)
    }

    private func withDefaults(_ operation: (UserDefaults) throws -> Void) throws {
        let suite = "ChatMuteActionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try operation(defaults)
    }
}
