import SwiftUI

/// Lets the recovery screens use a sample session without touching live accounts.
@MainActor
protocol AccountSetupSession {
    var isFinishingAccountSetup: Bool { get }
    var canUseRuntimeForLocalForegroundWork: Bool { get }
    var runtimeGeneration: Int { get }
    func connectAccountSetup() async
    func cancelAccountSetup() async -> Bool
    func finishAccountSetup() async
}

extension AppState: AccountSetupSession {}

#if DEBUG
extension EnvironmentValues {
    @Entry var accountSetupScenarioSession: (any AccountSetupSession)? = nil
}
#endif

@propertyWrapper
struct CurrentAccountSetupSession: DynamicProperty {
    @Environment(AppState.self) private var appState
    #if DEBUG
    @Environment(\.accountSetupScenarioSession) private var scenarioSession
    #endif

    var wrappedValue: any AccountSetupSession {
        #if DEBUG
        if let scenarioSession { return scenarioSession }
        #endif
        return appState
    }
}
