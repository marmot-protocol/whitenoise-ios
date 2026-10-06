import MarmotKit
import SwiftUI

struct AccountSetupProfileView: View {
    let model: AccountSetupModel

    var body: some View {
        NavigationStack { IdentityProfileSetupView(accountSetup: model) }
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
    }
}

nonisolated struct AccountSetupProfilePresentation {
    enum Action { case save, retry, skip, cancelRepair }

    struct Failure {
        let action: Action
        let message: String
    }

    let profile: UserProfileMetadataFfi?
    let canEdit: Bool
    let canRetry: Bool
    let canSkip: Bool
    let canCancelRepair: Bool
    let isInterrupted: Bool
    let lookupExplanation: String?

    init(snapshot: OnboardingSnapshotFfi) {
        let step = snapshot.steps.first { $0.step == .profile }
        let actions = step?.actions ?? []
        let proposal = snapshot.proposal.flatMap { $0.step == .profile ? $0 : nil }
        profile = proposal?.profile
        isInterrupted = proposal != nil && !actions.contains(.approveRepair) && !actions.contains(.cancelRepair)
        canEdit = !isInterrupted && (actions.contains(.editProfile) || actions.contains(.approveRepair))
        canRetry = actions.contains(.retry)
        canSkip = !isInterrupted && actions.contains(.continueWithout)
        canCancelRepair = actions.contains(.cancelRepair)
        lookupExplanation = step?.findings.lazy.compactMap { finding -> String? in
            switch finding.issue {
            case .timedOut: L10n.string("The service we checked took too long to respond.")
            case .unreachable: L10n.string("We couldn’t connect to the service that provides your profile.")
            case .malformed: L10n.string("We found profile information, but couldn’t read it.")
            default: nil
            }
        }.first
    }

    func retryAction(failedAction: Action?, hasFailure: Bool) -> Action? {
        if hasFailure {
            switch failedAction {
            case .save where canEdit: return .save
            case .skip where canSkip: return .skip
            case .cancelRepair where canCancelRepair: return .cancelRepair
            default: return canRetry ? .retry : nil
            }
        }
        return !canEdit && canRetry ? .retry : nil
    }

    static func shouldDismiss(after action: Action, snapshot: OnboardingSnapshotFfi, errorMessage: String?) -> Bool {
        guard errorMessage == nil else { return false }
        switch action {
        case .cancelRepair: return snapshot.proposal == nil
        case .skip: return snapshot.steps.first { $0.step == .profile }?.status == .skipped
        case .save, .retry: return snapshot.steps.first { $0.step == .profile }?.status == .passed
        }
    }
}

struct AccountSetupProfileStatus<PrivacyContent: View>: View {
    let presentation: AccountSetupProfilePresentation
    let failureMessage: String?
    let failedAction: AccountSetupProfilePresentation.Action?
    @ViewBuilder var privacyContent: () -> PrivacyContent

    private var isFailure: Bool { failureMessage != nil || presentation.isInterrupted || !presentation.canEdit }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isFailure ? "exclamationmark.circle" : "person.crop.circle")
                .foregroundStyle(isFailure ? Color.red : Color.primary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .fontWeight(.semibold)
                        .foregroundStyle(isFailure ? Color.red : Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(message)
                        .fixedSize(horizontal: false, vertical: true)
                }
                privacyContent()
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var title: LocalizedStringKey {
        if failureMessage != nil {
            if presentation.canEdit {
                return failedAction == .save ? "Couldn’t save your profile" : "Couldn’t continue signing in"
            }
            if failedAction != .retry, failedAction != .save { return "Couldn’t continue signing in" }
        }
        if presentation.isInterrupted { return "Your profile update didn’t finish" }
        if presentation.profile != nil { return "Review your profile" }
        return presentation.canEdit ? "Add your profile" : "Couldn’t load your profile"
    }

    private var message: String {
        if let failureMessage { return failureMessage }
        if presentation.isInterrupted {
            return L10n.string("We couldn’t finish sharing your changes. Try again to complete the update.")
        }
        if presentation.profile != nil {
            return L10n.string("These changes haven’t been shared yet. Check the details below, then save to update your public profile.")
        }
        if presentation.canEdit {
            return L10n.string("A name and photo help people recognize you. You can add them now or later in Settings.")
        }
        let explanation = presentation.lookupExplanation ?? L10n.string("We couldn’t get your profile details.")
        let nextStep = presentation.canSkip
            ? L10n.string("Try again, or continue signing in without changing your profile.")
            : L10n.string("Try again to continue.")
        return explanation + " " + nextStep
    }
}

struct AccountSetupProfileError: View {
    let title: LocalizedStringKey
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .fontWeight(.semibold)
                    .foregroundStyle(.red)
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AccountSetupProfileSummary: View {
    let profile: UserProfileMetadataFfi

    var body: some View {
        VStack(spacing: 16) {
            WNAvatarPreview(
                name: ContentSanitizer.displayName(profile.displayName ?? profile.name) ?? "",
                pictureURL: ContentSanitizer.imageURL(profile.picture)
            )
            .containerRelativeFrame(.horizontal, count: 3, span: 1, spacing: 0)
            if let name = ContentSanitizer.displayName(profile.displayName ?? profile.name) {
                Text(name).font(.title2.bold())
                    .multilineTextAlignment(.center)
            }
            if let about = ContentSanitizer.multilineText(profile.about), !about.isEmpty {
                Text(about).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
