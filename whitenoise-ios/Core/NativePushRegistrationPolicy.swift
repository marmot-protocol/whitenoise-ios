import MarmotKit

nonisolated enum NativePushRegistrationPolicy {
    static func enabledAccountRefs(
        accounts: [AccountSummaryFfi],
        settingsFor: (String) -> NotificationSettingsFfi?
    ) -> [String] {
        enabledAccountRefs(accountRefs: accounts.map(\.label), settingsFor: settingsFor)
    }

    static func enabledAccountRefs(
        accountRefs: [String],
        settingsFor: (String) -> NotificationSettingsFfi?
    ) -> [String] {
        accountRefs.compactMap { accountRef in
            guard settingsFor(accountRef)?.nativePushEnabled == true else { return nil }
            return accountRef
        }
    }

    static func shouldRequestRemoteToken(accountRefs: [String], currentToken: String?) -> Bool {
        !accountRefs.isEmpty && (currentToken?.isEmpty ?? true)
    }
}
