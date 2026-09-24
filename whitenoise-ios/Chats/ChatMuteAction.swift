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

    func deadline(from now: Date) -> Date? {
        let seconds: TimeInterval
        switch self {
        case .oneHour: seconds = 60 * 60
        case .eightHours: seconds = 8 * 60 * 60
        case .oneDay: seconds = 24 * 60 * 60
        case .oneWeek: seconds = 7 * 24 * 60 * 60
        case .always: return nil
        }
        return now.addingTimeInterval(seconds)
    }
}

nonisolated enum ChatMuteAction: Sendable {
    case mute(ChatMuteDuration)
    case unmute

    func perform(
        accountIdHex: String,
        groupIdHex: String,
        defaults: UserDefaults,
        now: Date = .now
    ) {
        switch self {
        case .mute(let duration):
            if let deadline = duration.deadline(from: now) {
                ChatMuteStore.setTimedMute(
                    until: deadline,
                    accountIdHex: accountIdHex, groupIdHex: groupIdHex, defaults: defaults
                )
            } else {
                ChatMuteStore.setNotifyMode(.nothing, accountIdHex: accountIdHex, groupIdHex: groupIdHex, defaults: defaults)
            }
        case .unmute:
            ChatMuteStore.setNotifyMode(.all, accountIdHex: accountIdHex, groupIdHex: groupIdHex, defaults: defaults)
        }
    }
}
