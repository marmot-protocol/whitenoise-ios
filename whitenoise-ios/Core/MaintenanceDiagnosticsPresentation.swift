import Foundation
import MarmotKit

nonisolated enum MaintenanceDiagnosticsPresentation {
    static func phaseLabel(_ phase: MaintenancePhaseFfi) -> String {
        switch phase {
        case .catchUp: "Catch-up"
        case .eoseTimeout: "EOSE timeout"
        case .grace: "Grace"
        case .quiet: "Quiet"
        case .jitter: "Jitter"
        case .overdue: "Overdue"
        case .paused: "Paused"
        case .clockSkewBlocked: "Clock skew blocked"
        case .pendingPublication: "Pending publication"
        case .fanout: "Fanout"
        case .retry: "Retry"
        case .supersededByConvergence: "Superseded by convergence"
        case .complete: "Complete"
        case .failed: "Failed"
        }
    }

    static func triggerLabel(_ trigger: MaintenanceTriggerFfi) -> String {
        switch trigger {
        case .postJoin: "Post-join"
        case .periodic: "Periodic"
        case .manual: "Manual"
        }
    }

    static func evolutionPhaseLabel(_ phase: GroupEvolutionPhaseFfi) -> String {
        switch phase {
        case .preparing: "Preparing"
        case .prepared: "Prepared"
        case .attempting: "Attempting"
        case .confirmed: "Confirmed"
        case .supersededByConvergence: "Superseded by convergence"
        }
    }

    static func obligationSummary(
        total: UInt64,
        overdue: UInt64,
        locale: Locale = AppLanguage.currentLocale
    ) -> String {
        L10n.formatted(
            "%@, %@",
            arguments: [
                L10n.plural("%llu total", total, locale: locale),
                L10n.plural("%llu overdue", overdue, locale: locale)
            ],
            locale: locale
        )
    }

    static func fanoutSummary(
        records: UInt64,
        failedTargets: UInt64,
        locale: Locale = AppLanguage.currentLocale
    ) -> String {
        L10n.formatted(
            "%@, %@",
            arguments: [
                L10n.plural("%llu records", records, locale: locale),
                L10n.plural("%llu failed targets", failedTargets, locale: locale)
            ],
            locale: locale
        )
    }

    static func failureCode(_ raw: String?) -> String? {
        ContentSanitizer.compactSingleLine(raw, maxLength: 120)
    }

    static func date(_ timestamp: UInt64?) -> Date? {
        guard let timestamp else { return nil }
        let seconds = min(TimeInterval(timestamp), Date.distantFuture.timeIntervalSince1970)
        return Date(timeIntervalSince1970: seconds)
    }
}
