import MarmotKit
import SwiftUI

struct AccountSetupRelaySheet: View {
    let model: AccountSetupModel
    let step: OnboardingStepFfi
    @State private var draft = AccountSetupRelayDraft()

    var body: some View {
        AccountSetupRelayEditor(model: model, step: step, draft: $draft)
    }
}
