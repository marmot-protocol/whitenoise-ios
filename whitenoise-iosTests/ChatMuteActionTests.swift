import Foundation
import Testing
@testable import whitenoise_ios

struct ChatMuteActionTests {
    @Test func durationsProduceAbsoluteMillisecondDeadlines() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(ChatMuteDuration.oneHour.deadlineMilliseconds(from: now) == 1_800_003_600_000)
        #expect(ChatMuteDuration.eightHours.deadlineMilliseconds(from: now) == 1_800_028_800_000)
        #expect(ChatMuteDuration.oneDay.deadlineMilliseconds(from: now) == 1_800_086_400_000)
        #expect(ChatMuteDuration.oneWeek.deadlineMilliseconds(from: now) == 1_800_604_800_000)
        #expect(ChatMuteDuration.always.deadlineMilliseconds(from: now) == nil)
    }

    @Test func failedNativeMutationPreservesLegacyMute() throws {
        try withDefaults { defaults in
            let key = try #require(ChatMuteStore.key(accountIdHex: "aa", groupIdHex: "01"))
            defaults.set([key], forKey: ChatMuteStore.storageKey)
            #expect(throws: NativeFailure.self) {
                try ChatMuteAction.mute(.oneHour).perform(groupIdHex: "01", defaults: defaults) {
                    throw NativeFailure()
                }
            }
            #expect(ChatMuteStore.mutedChatKeys(defaults: defaults) == [key])
            #expect(defaults.dictionary(forKey: ChatMuteStore.notifyModeStorageKey) == nil)
        }
    }

    @Test func timedReplacementRetiresOnlyTheSuccessfulChatsLegacyMute() throws {
        try withDefaults { defaults in
            for (account, group) in [("aa", "01"), ("aa", "02"), ("bb", "01")] {
                ChatMuteStore.setNotifyMode(.nothing, accountIdHex: account, groupIdHex: group, defaults: defaults)
            }
            ChatMuteAction.mute(.oneHour).perform(groupIdHex: "01", defaults: defaults) { "aa" }
            let snapshot = ChatMuteStore.notifyModeSnapshot(defaults: defaults)
            #expect(ChatMuteStore.notifyMode(accountIdHex: "aa", groupIdHex: "01", in: snapshot) == .all)
            #expect(!ChatMuteStore.isMuted(accountIdHex: "aa", groupIdHex: "01", defaults: defaults))
            #expect(ChatMuteStore.notifyMode(accountIdHex: "aa", groupIdHex: "02", in: snapshot) == .nothing)
            #expect(ChatMuteStore.notifyMode(accountIdHex: "bb", groupIdHex: "01", in: snapshot) == .nothing)
        }
    }

    @Test func timedMutePreservesMentionsOnlyForAfterExpiry() throws {
        try withDefaults { defaults in
            ChatMuteStore.setNotifyMode(.mentionsOnly, accountIdHex: "aa", groupIdHex: "01", defaults: defaults)
            ChatMuteAction.mute(.eightHours).perform(groupIdHex: "01", defaults: defaults) { "aa" }
            #expect(ChatMuteStore.notifyMode(
                accountIdHex: "aa", groupIdHex: "01", in: ChatMuteStore.notifyModeSnapshot(defaults: defaults)
            ) == .mentionsOnly)
        }
    }

    @Test func explicitUnmuteClearsHostSuppressionOnlyAfterNativeSuccess() throws {
        try withDefaults { defaults in
            ChatMuteStore.setNotifyMode(.nothing, accountIdHex: "aa", groupIdHex: "01", defaults: defaults)
            var nativeWasCleared = false
            ChatMuteAction.unmute.perform(groupIdHex: "01", defaults: defaults) {
                #expect(ChatMuteStore.isMuted(accountIdHex: "aa", groupIdHex: "01", defaults: defaults))
                nativeWasCleared = true
                return "aa"
            }
            #expect(nativeWasCleared)
            #expect(ChatMuteStore.notifyMode(
                accountIdHex: "aa", groupIdHex: "01", in: ChatMuteStore.notifyModeSnapshot(defaults: defaults)
            ) == .all)
        }
    }

    private struct NativeFailure: Error { }

    private func withDefaults(_ operation: (UserDefaults) throws -> Void) throws {
        let suite = "ChatMuteActionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try operation(defaults)
    }
}
