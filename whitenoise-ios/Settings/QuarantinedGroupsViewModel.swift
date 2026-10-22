import Foundation
import MarmotKit

@MainActor
protocol QuarantinedGroupsDataSource: AnyObject {
    var activeAccountRef: String? { get }

    func loadQuarantinedGroups(accountRef: String) async throws -> [AppQuarantinedGroupFfi]
    func retryHydrateQuarantinedGroup(accountRef: String, groupIdHex: String) async throws -> Bool
    func present(_ toast: Toast)
}

extension AppState: QuarantinedGroupsDataSource {
    func loadQuarantinedGroups(accountRef: String) async throws -> [AppQuarantinedGroupFfi] {
        try await currentMarmotClient().quarantinedGroups(accountRef: accountRef)
    }

    func retryHydrateQuarantinedGroup(
        accountRef: String,
        groupIdHex: String
    ) async throws -> Bool {
        try await currentMarmotClient().retryHydrateQuarantinedGroup(
            accountRef: accountRef,
            groupIdHex: groupIdHex
        )
    }
}

nonisolated enum QuarantinedGroupPresentation {
    struct Reason: Equatable {
        let title: String
        let guidance: String
    }

    static func reason(_ reason: AppGroupHydrationQuarantineReasonFfi) -> Reason {
        switch reason {
        case .openMlsLoadFailed:
            Reason(
                title: L10n.string("OpenMLS load failed"),
                guidance: L10n.string("The stored MLS session could not be opened. Retry may help if storage was temporarily unavailable.")
            )
        case .openMlsGroupMissing:
            Reason(
                title: L10n.string("OpenMLS group missing"),
                guidance: L10n.string("Marmot has group metadata, but the corresponding OpenMLS state is missing. Retry only helps if that state becomes available.")
            )
        case .memberValidationFailed:
            Reason(
                title: L10n.string("Member validation failed"),
                guidance: L10n.string("Loaded member credentials or ratchet-tree state failed validation. Retry does not bypass that validation.")
            )
        case .groupRecordLoadFailed:
            Reason(
                title: L10n.string("Group record load failed"),
                guidance: L10n.string("The stored Marmot group record could not be read or refreshed. Retry may help after a transient storage failure.")
            )
        case .pendingCommitRecoveryFailed:
            Reason(
                title: L10n.string("Pending commit recovery failed"),
                guidance: L10n.string("Marmot found a stranded MLS commit but could not recover it. Retry re-runs the same non-destructive recovery.")
            )
        @unknown default:
            Reason(
                title: L10n.string("Unknown quarantine reason"),
                guidance: L10n.string("This MDK build reported a quarantine reason the app does not recognize.")
            )
        }
    }

    static func sorted(_ groups: [AppQuarantinedGroupFfi]) -> [AppQuarantinedGroupFfi] {
        groups.sorted { $0.groupIdHex < $1.groupIdHex }
    }
}

@MainActor
@Observable
final class QuarantinedGroupsViewModel {
    // Avoid the isolated-deinit task-local crash on older Swift runtimes (including iOS 26.2).
    // https://github.com/swiftlang/swift/issues/88036
    nonisolated deinit {}

    enum RetryStatus: Equatable {
        case stillQuarantined
        case failed(String)
    }

    var groups: [AppQuarantinedGroupFfi] = []
    var isLoading = false
    var loadError: String?
    var retryStatusByGroupId: [String: RetryStatus] = [:]
    private(set) var retryingGroupIds: Set<String> = []

    private var loadedAccountRef: String?
    private var reloadTicket = 0
    private var retryTickets: [String: UUID] = [:]

    func reset() {
        reloadTicket &+= 1
        loadedAccountRef = nil
        groups = []
        loadError = nil
        retryStatusByGroupId = [:]
        retryTickets = [:]
        retryingGroupIds = []
        isLoading = false
    }

    func reload(using dataSource: any QuarantinedGroupsDataSource) async {
        guard let accountRef = dataSource.activeAccountRef else {
            reset()
            return
        }

        reloadTicket &+= 1
        let ticket = reloadTicket
        if loadedAccountRef != accountRef {
            groups = []
            retryStatusByGroupId = [:]
            retryTickets = [:]
            retryingGroupIds = []
        }
        isLoading = true
        loadError = nil
        defer {
            if reloadTicket == ticket {
                isLoading = false
            }
        }

        do {
            let loaded = try await dataSource.loadQuarantinedGroups(accountRef: accountRef)
            guard !Task.isCancelled,
                  reloadTicket == ticket,
                  dataSource.activeAccountRef == accountRef
            else { return }

            let sorted = QuarantinedGroupPresentation.sorted(loaded)
            let liveIds = Set(sorted.map(\.groupIdHex))
            groups = sorted
            retryStatusByGroupId = retryStatusByGroupId.filter { liveIds.contains($0.key) }
            loadedAccountRef = accountRef
        } catch is CancellationError {
            return
        } catch {
            guard reloadTicket == ticket, dataSource.activeAccountRef == accountRef else { return }
            loadError = UserFacingError.sanitizedDiagnostic(for: error)
        }
    }

    func retry(_ group: AppQuarantinedGroupFfi, using dataSource: any QuarantinedGroupsDataSource) async {
        guard let accountRef = dataSource.activeAccountRef,
              retryTickets[group.groupIdHex] == nil
        else { return }

        let ticket = UUID()
        retryTickets[group.groupIdHex] = ticket
        retryingGroupIds.insert(group.groupIdHex)
        retryStatusByGroupId[group.groupIdHex] = nil
        defer {
            if retryTickets[group.groupIdHex] == ticket {
                retryTickets[group.groupIdHex] = nil
                retryingGroupIds.remove(group.groupIdHex)
            }
        }

        do {
            let recovered = try await dataSource.retryHydrateQuarantinedGroup(
                accountRef: accountRef,
                groupIdHex: group.groupIdHex
            )
            guard !Task.isCancelled,
                  dataSource.activeAccountRef == accountRef,
                  retryTickets[group.groupIdHex] == ticket
            else { return }

            if recovered {
                groups.removeAll { $0.groupIdHex == group.groupIdHex }
                retryStatusByGroupId[group.groupIdHex] = nil
                Haptics.success()
                dataSource.present(.success(L10n.string("Group recovered")))
            } else {
                retryStatusByGroupId[group.groupIdHex] = .stillQuarantined
                Haptics.warning()
                dataSource.present(.warning(L10n.string("Group is still quarantined")))
            }
            await reload(using: dataSource)
        } catch is CancellationError {
            return
        } catch {
            guard dataSource.activeAccountRef == accountRef,
                  retryTickets[group.groupIdHex] == ticket
            else { return }
            let diagnostic = UserFacingError.sanitizedDiagnostic(for: error)
            retryStatusByGroupId[group.groupIdHex] = .failed(diagnostic)
            Haptics.error()
            dataSource.present(UserFacingError.toast(
                title: L10n.string("Recovery retry failed"),
                error: error
            ))
        }
    }
}
