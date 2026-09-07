import SwiftUI
import MarmotKit

struct AccountSetupActions: View {
    @Bindable var model: AccountSetupModel
    let editProfile: () -> Void
    let chooseDiscovery: () -> Void

    private var step: OnboardingStepStateFfi? {
        if let proposal = model.snapshot.proposal {
            return model.snapshot.steps.first { $0.step == proposal.step }
        }
        return model.currentStep
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let step, step.status != .pending, step.status != .checking {
                if model.snapshot.proposal != nil,
                   !step.actions.contains(.approveRepair), !step.actions.contains(.cancelRepair) {
                    unfinishedRepair(step)
                } else if let proposal = model.snapshot.proposal,
                          proposal.step == .relays || proposal.step == .inboxRelays {
                    relayProposal(proposal)
                } else {
                    switch step.step {
                    case .profile: profilePrompt(step)
                    case .follows:
                        if model.errorMessage == nil {
                            ProgressView("Continuing setup…")
                        } else if step.actions.contains(.continueWithout) {
                            WNButton(title: "Continue") { model.send(.skip(.follows)) }
                        }
                    case .relays, .inboxRelays: relayChoices(step)
                    case .singleDevice: deviceNotice(step)
                    case .keyPackage:
                        if step.actions.contains(.retry) {
                            WNButton(title: "Try again") { model.send(.retry(step.step)) }
                        }
                    }
                }
            }
            if model.isBusy { ProgressView("Saving progress…") }
        }
        .disabled(model.isBusy || !model.isConnected)
    }

    private func profilePrompt(_ step: OnboardingStepStateFfi) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Update your profile?", systemImage: "person.crop.circle")
                .font(.headline)
            if step.actions.contains(.editProfile) || step.actions.contains(.approveRepair) {
                Text("A name and photo help people recognize you. You can also do this later.")
                    .font(.subheadline).foregroundStyle(.secondary)
                WNButton(title: "Update profile", action: editProfile)
            } else {
                Text("We couldn’t load your profile. You can try again or continue without changing it.")
                    .font(.subheadline).foregroundStyle(.secondary)
                if step.actions.contains(.retry) {
                    WNButton(title: "Try again") { model.send(.retry(.profile)) }
                }
            }
            if step.actions.contains(.continueWithout) {
                WNButton(title: "Not now", emphasis: .secondary) { model.send(.skip(.profile)) }
            } else if step.actions.contains(.cancelRepair) {
                WNButton(title: "Back", emphasis: .secondary) { model.send(.cancelRepair) }
            }
        }
        .setupCard()
    }

    private func relayChoices(_ step: OnboardingStepStateFfi) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(step.step == .inboxRelays ? L10n.string("Find your inbox relays") : L10n.string("Find your relays"))
                    .font(.headline)
                Text(step.actions.contains(.useRecommendedRelays)
                     ? L10n.string("We couldn’t find a usable list. Look on a relay you’ve used before, or publish our defaults.")
                     : L10n.string("We couldn’t complete the lookup. Try another relay or check again before replacing any settings."))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if step.actions.contains(.editDiscoveryRelays) {
                WNButton(title: "Look on another relay", systemImage: "magnifyingglass",
                         emphasis: .secondary, action: chooseDiscovery)
            }
            if step.actions.contains(.useRecommendedRelays) {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("White Noise defaults").font(.subheadline.bold())
                    Text(step.step == .inboxRelays
                         ? L10n.string("Publish these two relays as your inbox so people know where to send invitations.")
                         : L10n.string("Publish these two relays as the places where your account reads and shares updates."))
                        .font(.subheadline).foregroundStyle(.secondary)
                    relayAddresses(MarmotClient.seedRelays)
                }
                WNButton(title: "Use default relays") { model.send(.useDefaults(step.step)) }
            } else if step.actions.contains(.retry) {
                WNButton(title: "Try again") { model.send(.retry(step.step)) }
            }
        }
        .setupCard()
    }

    private func relayProposal(_ proposal: OnboardingRepairProposalFfi) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Use these relays?", systemImage: "network")
                .font(.headline)
            Text(proposal.step == .inboxRelays
                 ? L10n.string("Publish these relays as your inbox so people know where to send invitations.")
                 : L10n.string("This publishes your public relay list. Other apps using this account may use it too."))
                .font(.subheadline).foregroundStyle(.secondary)
            if proposal.step == .inboxRelays || proposal.readRelays == proposal.writeRelays {
                relayAddresses(proposal.readRelays)
            } else {
                Text("Read relays").font(.subheadline.bold())
                relayAddresses(proposal.readRelays)
                Text("Write relays").font(.subheadline.bold())
                relayAddresses(proposal.writeRelays)
            }
            WNButton(title: "Use these relays") { model.send(.approve(model.snapshot.revision)) }
            WNButton(title: "Back", emphasis: .secondary) { model.send(.cancelRepair) }
        }
        .setupCard()
    }

    private func relayAddresses(_ relays: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(relays, id: \.self) { relay in
                Label(String(relay.prefix(2048)), systemImage: "server.rack")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func unfinishedRepair(_ step: OnboardingStepStateFfi) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Finish your saved update").font(.headline)
            Text("You already approved this change. Retry to finish saving it before continuing setup.")
                .font(.subheadline).foregroundStyle(.secondary)
            if step.actions.contains(.retry) {
                WNButton(title: "Try again") { model.send(.retry(step.step)) }
            }
        }
        .setupCard()
    }

    private func deviceNotice(_ step: OnboardingStepStateFfi) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if step.status == .needsInput {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Use White Noise on one device", systemImage: "iphone")
                        .font(.headline)
                    Text("White Noise does not yet sync conversations across devices. We recommend using this account on one device.")
                    if let notice = model.snapshot.singleDeviceNotice {
                        Text(AccountSetupPresentation.deviceNotice(notice.discovery))
                            .foregroundStyle(.secondary)
                        if !notice.discoveryComplete && notice.discovery == .otherInstallationPossible {
                            Text("Some discovery sources could not be checked.").foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.subheadline)
                .setupCard()
            }
            if step.actions.contains(.continueAnyway) {
                WNButton(title: LocalizedStringKey(AccountSetupPresentation.deviceAction(model.snapshot.singleDeviceNotice?.discovery))) {
                    model.send(.acknowledge(model.snapshot.revision))
                }
            } else if step.actions.contains(.retry) {
                WNButton(title: "Try again") { model.send(.retry(step.step)) }
            }
        }
    }
}

private extension View {
    func setupCard() -> some View {
        self.frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20).strokeBorder(.primary.opacity(0.06))
            }
    }
}
