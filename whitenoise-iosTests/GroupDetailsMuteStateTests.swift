import Foundation
import Testing
@testable import whitenoise_ios

@MainActor
struct GroupDetailsMuteStateTests {
    @Test func initialAndFailedLoadsShowUnavailable() {
        let model = GroupDetailsViewModel()
        #expect(model.notifyModeSummary == L10n.string("Unavailable"))

        for mode in ChatNotifyMode.allCases {
            model.notifyMode = mode
            model.isMuteStateLoaded = true
            model.muteExpiresAt = .distantFuture

            model.loadMuteState(accountIdHex: "owner", groupIdHex: "group", snapshot: nil)

            #expect(!model.isMuteStateLoaded)
            #expect(model.notifyModeSummary == L10n.string("Unavailable"))
            #expect(model.muteExpiresAt == nil)
            #expect(model.notifyModeError == L10n.string("Couldn't load notification settings"))
        }
    }

    @Test func successfulRetryRestoresTheCurrentModeAndExpiry() throws {
        let model = GroupDetailsViewModel()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let deadline = now.addingTimeInterval(3_600)
        let key = try #require(ChatMuteStore.key(accountIdHex: "owner", groupIdHex: "group"))
        model.loadMuteState(accountIdHex: "owner", groupIdHex: "group", snapshot: nil)
        model.loadMuteState(accountIdHex: "owner", groupIdHex: "group", snapshot: .init(
            modesByChatKey: [key: ChatNotifyMode.mentionsOnly.rawValue],
            legacyMutedChatKeys: [], mutedUntilByChatKey: [key: deadline.timeIntervalSince1970]
        ), now: now)

        #expect(model.isMuteStateLoaded)
        #expect(model.notifyModeError == nil)
        #expect(model.notifyModeSummary == L10n.string("Muted"))
        #expect(model.muteExpiresAt == deadline)

        model.loadMuteState(accountIdHex: "owner", groupIdHex: "group", snapshot: .init(
            modesByChatKey: [key: ChatNotifyMode.mentionsOnly.rawValue],
            legacyMutedChatKeys: [], mutedUntilByChatKey: [key: deadline.timeIntervalSince1970]
        ), now: deadline)
        #expect(model.notifyModeSummary == L10n.string("Mentions"))
        #expect(model.muteExpiresAt == nil)

        model.loadMuteState(accountIdHex: "owner", groupIdHex: "group", snapshot: .init(
            modesByChatKey: [:], legacyMutedChatKeys: [], mutedUntilByChatKey: [:]
        ), now: deadline)
        #expect(model.notifyModeSummary == L10n.string("On"))
    }
}
