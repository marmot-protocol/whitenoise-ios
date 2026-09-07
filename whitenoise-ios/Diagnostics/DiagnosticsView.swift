import SwiftUI
import MarmotKit

/// Developer-facing scratchpad. Lives behind the "Show diagnostics" toggle
/// in Settings. Streams the top-level event firehose into a scrollable log.
struct DiagnosticsView: View {
    @Environment(AppState.self) private var appState
    @State private var model = DiagnosticsViewModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    Task { await model.sendToSelf(using: appState) }
                } label: {
                    Label("Send to self", systemImage: "paperplane.fill")
                }
                .buttonStyle(.bordered)
                .disabled(model.sendingToSelf || appState.activeAccountRef == nil)

                Button {
                    model.clear()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .tint(.red)

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: model.streaming ? "dot.radiowaves.left.and.right" : "circle.dotted")
                        .foregroundStyle(model.streaming ? .green : .secondary)
                        .symbolEffect(.variableColor.iterative, isActive: model.streaming)
                    Text(model.streaming ? L10n.string("Live") : L10n.string("Idle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(model.entries) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Text(entry.text)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                            .id(entry.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: model.entries.count) { _, _ in
                    if let last = model.entries.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: appState.runtimeGeneration) {
            await model.runEventStream(using: appState)
        }
    }

    static func diagnosticText(for event: MarmotEventFfi) -> String {
        switch event {
        case .groupJoined(_, let label, let groupIdHex):
            return "[\(label)] joined group \(IdentityFormatter.short(groupIdHex))"
        case .groupStateUpdated(_, let label, let groupIdHex):
            return "[\(label)] group state ↺ \(IdentityFormatter.short(groupIdHex))"
        case .messageReceived(let received):
            return "[\(received.accountLabel)] msg from \(IdentityFormatter.short(received.message.sender)): \(plaintextSummary(received.message.plaintext))"
        case .projectionUpdated(let update):
            return "[\(update.accountLabel)] projection \(IdentityFormatter.short(update.update.groupIdHex))"
        case .groupEvent(_, let label, let groupIdHex, let event):
            return "[\(label)] group event \(groupEventLabel(event)) \(IdentityFormatter.short(groupIdHex))"
        case .accountError(_, let label, let message):
            return "[\(label)] error: \(message)"
        case .agentStreamActivity(_, let label):
            return "[\(label)] agent stream activity"
        case .welcomeDeliveryPending(_, let label, let groupIdHex, let messageIdHex, let recipientHex):
            return "[\(label)] welcome pending group \(IdentityFormatter.short(groupIdHex)) message \(IdentityFormatter.short(messageIdHex)) recipient \(IdentityFormatter.short(recipientHex))"
        case .epochStallEscalated(_, let label, let groupIdHex, let stalledEpoch, let arms):
            return "[\(label)] group \(IdentityFormatter.short(groupIdHex)) cannot catch up at epoch \(stalledEpoch) after \(arms) recovery attempts; re-sync recommended"
        case .groupChangeSuperseded(_, let label, let groupIdHex, let commitIdHex, let kind, let outcome, let reason):
            return "[\(label)] group \(IdentityFormatter.short(groupIdHex)) change \(kind) superseded commit \(IdentityFormatter.short(commitIdHex)): \(outcome) (\(reason))"
        }
    }

    static func performanceSnapshotText(_ snapshot: AppPerformanceSnapshotFfi) -> [String] {
        let operations: [(String, AppPerformanceOperationSnapshotFfi)] = [
            ("app start", snapshot.appStart),
            ("directory subscription", snapshot.directorySubscriptionSync),
            ("account reconcile", snapshot.accountReconcile),
            ("account open", snapshot.accountOpen),
            ("account worker readiness", snapshot.accountWorkerReadiness),
            ("account session open", snapshot.accountSessionOpen),
            ("group hydration", snapshot.accountGroupHydration),
            ("profile load", snapshot.accountProfileLoad),
            ("group snapshot read", snapshot.accountGroupReadSnapshot),
            ("transport activation", snapshot.accountTransportActivation),
            ("subscription registration", snapshot.accountSubscriptionRegistration),
            ("account catch-up", snapshot.accountCatchUp),
            ("account sync", snapshot.accountSync),
            ("account setup", snapshot.accountSetupAdvisoryStep),
            ("account bootstrap publish", snapshot.accountBootstrapRelayAndFollowPublish),
            ("account default profile publish", snapshot.accountDefaultProfilePublish),
            ("account initial key package publish", snapshot.accountInitialKeyPackagePublish),
            ("account initial sync overlap", snapshot.accountInitialSyncOverlap),
            ("account setup identity local", snapshot.accountSetupIdentityLocal),
            ("account setup storage local", snapshot.accountSetupStorageLocal),
            ("account setup profile local", snapshot.accountSetupProfileLocal),
            ("account setup key package local", snapshot.accountSetupKeyPackageLocal),
            ("account setup local-ready handoff", snapshot.accountSetupLocalReadyHandoff),
            ("account setup network ready", snapshot.accountSetupNetworkReady),
            ("message send", snapshot.outboundMessageSend),
            ("group create queue", snapshot.groupCreateQueueWait),
            ("group create key packages", snapshot.groupCreateKeyPackageLookup),
            ("group member key-package prewarm", snapshot.groupMemberKeyPackagePrewarm),
            ("group create key-package cache reuse", snapshot.groupCreateKeyPackageCacheReuse),
            ("group create key-package network", snapshot.groupCreateKeyPackageNetworkResolution),
            ("group create image preprocess", snapshot.groupCreateImagePreprocess),
            ("group create image upload", snapshot.groupCreateImageUpload),
            ("group create MLS", snapshot.groupCreateMlsPreparePersist),
            ("group create pending Welcome index", snapshot.groupCreatePendingWelcomeIndex),
            ("group create welcome", snapshot.groupCreateWelcomePublish),
            ("group create projection", snapshot.groupCreateLocalProjectionSave),
            ("group create response handoff", snapshot.groupCreateResponseHandoff),
            ("group create subscriptions", snapshot.groupCreateSubscriptionRefresh),
            ("group create catch-up", snapshot.groupCreatePostMutationCatchUp),
            ("group create total", snapshot.groupCreateTotalCallerLatency),
            ("invite members", snapshot.groupInviteMembers),
            ("invite key packages", snapshot.groupInviteKeyPackageLookup),
            ("invite routing", snapshot.groupInviteRoutingRefresh),
            ("invite pre-send sync", snapshot.groupInvitePreSendSync),
            ("invite publish", snapshot.groupInviteEnginePublish),
            ("invite local refresh", snapshot.groupInviteLocalRefresh),
            ("invite notification", snapshot.groupInviteNotificationTrigger),
            ("invite Welcome publish", snapshot.groupInviteWelcomePublish),
            ("invite catch-up", snapshot.groupInvitePostMutationCatchUp),
            ("promote admin", snapshot.groupPromoteAdmin),
            ("group details", snapshot.groupDetailsRead),
            ("group conversation snapshot", snapshot.groupConversationSnapshotRead),
            ("chat-list row", snapshot.chatListRowRead),
            ("existing direct chat", snapshot.existingDirectConversationRead),
            ("group MLS state", snapshot.groupMlsStateRead),
            ("group roster", snapshot.groupRosterRead),
            ("accept invite", snapshot.groupAcceptInvite),
            ("media upload", snapshot.mediaUpload),
            ("media download", snapshot.mediaDownload),
            ("splash ready", snapshot.hostSplashReady),
            ("foreground local ready", snapshot.hostForegroundLocalReady),
        ]
        var lines = operations.compactMap { label, operation in
            performanceOperationText(label: label, snapshot: operation)
        }
        if snapshot.sqlcipherMigrationProbeRuns > 0 || snapshot.sqlcipherMigrationProbeSkips > 0 {
            lines.append(
                "[perf] SQLCipher migration probes: ran \(snapshot.sqlcipherMigrationProbeRuns), skipped \(snapshot.sqlcipherMigrationProbeSkips)"
            )
        }
        return lines
    }

    static func relayHealthText(_ health: RelayHealthFfi) -> [String] {
        [
            "[relay] connections: \(health.connected)/\(health.totalRelays) connected, \(health.connecting) connecting, \(health.pending) pending, \(health.disconnected) disconnected, \(health.sleeping) sleeping, \(health.terminated) terminated, \(health.banned) banned",
            "[relay] attempts: \(health.connectionSuccesses)/\(health.connectionAttempts) succeeded; initialized \(health.initialized); SDK-backed \(health.sdkBacked ? "yes" : "no")",
            "[relay] notification forwarder: \(health.notificationForwarderRunning ? "running" : "stopped"), \(health.notificationForwarderRestarts) restarts, \(health.notificationForwarderLagIncidents) lag incidents / \(health.notificationForwarderLaggedNotifications) notifications, \(health.notificationForwarderPanics) panics, \(health.notificationForwarderUnexpectedExits) unexpected exits",
        ]
    }

    static func performanceOperationText(
        label: String,
        snapshot: AppPerformanceOperationSnapshotFfi
    ) -> String? {
        guard snapshot.attempts > 0 else { return nil }
        let averageMs = snapshot.durationMs.sumMs / snapshot.attempts
        let p50 = percentileText(snapshot.durationMs, percentile: 0.50)
        let p95 = percentileText(snapshot.durationMs, percentile: 0.95)
        return "[perf] \(label): \(snapshot.attempts) attempts, \(snapshot.successes) succeeded, \(snapshot.failures) failed, \(snapshot.durationMs.sumMs) ms total, \(averageMs) ms avg, p50 \(p50), p95 \(p95)"
    }

    static func percentileText(
        _ histogram: DurationHistogramSnapshotFfi,
        percentile: Double
    ) -> String {
        let sampleCount = histogram.buckets.reduce(UInt64.zero) { $0 &+ $1.count }
            &+ histogram.overflowCount
        guard sampleCount > 0 else { return "n/a" }
        let clamped = min(1, max(0, percentile))
        let rank = max(UInt64(1), UInt64(ceil(Double(sampleCount) * clamped)))
        var cumulative: UInt64 = 0
        for bucket in histogram.buckets {
            cumulative &+= bucket.count
            if cumulative >= rank {
                return "≤\(bucket.upperBoundMs) ms"
            }
        }
        guard let upperBound = histogram.buckets.last?.upperBoundMs else { return "overflow" }
        return ">\(upperBound) ms"
    }

    private static func plaintextSummary(_ plaintext: String) -> String {
        plaintext.isEmpty ? "(empty)" : "(\(plaintext.count) chars)"
    }

    static func notificationServiceDiagnosticText(
        _ snapshot: NotificationServiceDiagnosticSnapshot,
        locale: Locale = AppLanguage.currentLocale
    ) -> String {
        let recordedAt = snapshot.recordedAt.formatted(
            Date.FormatStyle(date: .abbreviated, time: .standard).locale(locale)
        )
        let duration = Duration.milliseconds(snapshot.durationMilliseconds).formatted(
            .units(allowed: [.milliseconds], width: .abbreviated).locale(locale)
        )
        let notificationCount = L10n.plural(
            "%lld notifications",
            Int64(snapshot.notificationCount),
            locale: locale
        )
        return L10n.formatted(
            "[NSE %@] %@ at %@ in %@ (%@)",
            arguments: [
                recordedAt,
                snapshot.outcome.rawValue,
                snapshot.stage.rawValue,
                duration,
                notificationCount
            ],
            locale: locale
        )
    }

    private static func groupEventLabel(_ event: GroupEventKindFfi) -> String {
        switch event {
        case .groupCreated:
            return "created"
        case .groupJoined:
            return "joined"
        case .transportObjectResourceRefused:
            return "resource refused"
        case .messageReceived:
            return "message"
        case .appMessageInvalidated:
            return "message invalidated"
        case .groupStateChanged:
            return "state changed"
        case .groupHydrationQuarantined:
            return "hydration quarantined"
        case .epochChanged:
            return "epoch changed"
        case .commitRolledBack:
            return "commit rolled back"
        case .groupStateInvalidated:
            return "state invalidated"
        case .groupStateRevalidated:
            return "state revalidated"
        case .groupUnrecoverable:
            return "unrecoverable"
        case .pendingCommitRecovered:
            return "pending commit recovered"
        case .groupHydrationRecovered:
            return "hydration recovered"
        }
    }

}

enum DiagnosticSelfSend {
    static let groupName = "Self check"

    private static let defaultsKeyPrefix = "marmot.diagnostics.selfGroupId."

    static func reusableGroup(
        accountRef: String,
        rows: [ChatListRowFfi],
        defaults: UserDefaults = .standard
    ) -> ChatListRowFfi? {
        guard let storedGroupId = storedGroupId(accountRef: accountRef, defaults: defaults) else {
            return nil
        }
        return rows.first { $0.groupIdHex == storedGroupId }
    }

    static func remember(
        groupIdHex: String,
        accountRef: String,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(groupIdHex, forKey: defaultsKey(accountRef: accountRef))
    }

    static func pingText(now: Date) -> String {
        "ping at \(now.formatted(date: .omitted, time: .standard))"
    }

    private static func storedGroupId(
        accountRef: String,
        defaults: UserDefaults
    ) -> String? {
        defaults.string(forKey: defaultsKey(accountRef: accountRef))
    }

    private static func defaultsKey(accountRef: String) -> String {
        defaultsKeyPrefix + accountRef
    }
}
