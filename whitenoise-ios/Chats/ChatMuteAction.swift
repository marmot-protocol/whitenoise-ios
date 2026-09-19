import Foundation

nonisolated enum ChatMuteDuration: CaseIterable, Sendable {
    case oneHour, eightHours, oneDay, oneWeek, always

    var title: String {
        switch self {
        case .oneHour: L10n.string("1 Hour")
        case .eightHours: L10n.string("8 Hours")
        case .oneDay: L10n.string("1 Day")
        case .oneWeek: L10n.string("1 Week")
        case .always: L10n.string("Always")
        }
    }

    func deadlineMilliseconds(from now: Date) -> Int64? {
        let seconds: TimeInterval
        switch self {
        case .oneHour: seconds = 60 * 60
        case .eightHours: seconds = 8 * 60 * 60
        case .oneDay: seconds = 24 * 60 * 60
        case .oneWeek: seconds = 7 * 24 * 60 * 60
        case .always: return nil
        }
        return Int64((now.timeIntervalSince1970 + seconds) * 1_000)
    }
}

nonisolated enum ChatMuteAction: Sendable {
    case mute(ChatMuteDuration)
    case unmute

    /// MDK owns the mute and its expiry. Keep mentions-only underneath it,
    /// but retire a legacy indefinite mute after an explicit replacement.
    func localModeAfterSuccess(previous: ChatNotifyMode) -> ChatNotifyMode {
        switch self {
        case .mute: previous == .mentionsOnly ? .mentionsOnly : .all
        case .unmute: .all
        }
    }

    func perform(
        groupIdHex: String,
        defaults: UserDefaults,
        updateNative: () throws -> String
    ) rethrows {
        let accountIdHex = try updateNative()
        let previous = ChatMuteStore.notifyMode(
            accountIdHex: accountIdHex, groupIdHex: groupIdHex,
            in: ChatMuteStore.notifyModeSnapshot(defaults: defaults)
        )
        ChatMuteStore.setNotifyMode(
            localModeAfterSuccess(previous: previous),
            accountIdHex: accountIdHex, groupIdHex: groupIdHex, defaults: defaults
        )
    }
}
