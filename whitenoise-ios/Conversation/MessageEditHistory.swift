import SwiftUI
import MarmotKit

/// Legacy raw-timeline edit history formatting. Prepared conversations load
/// accepted versions directly from MDK in the sheet below.
nonisolated enum EditHistoryPresentation {
    /// Bounds sanitized row bodies to the plain-text flattener's own budget,
    /// so hostile content is capped once, consistently.
    static let maxRowBodyLength = 1000

    struct Row: Identifiable, Equatable {
        /// The version's own message id (edits and the original are distinct records).
        let id: String
        /// 0 for the original, then 1... in the order the edits were applied.
        let versionNumber: Int
        /// Sanitized plain text via the budgeted flattener.
        let body: String
        let recordedAt: UInt64
        let isCurrent: Bool
        let isOriginal: Bool
    }

    /// The actions-menu gate: history exists only once a durable edit landed,
    /// and a deleted message hides its edit trail like it hides its body.
    static func shouldOffer(editCount: Int, isDeleted: Bool) -> Bool {
        editCount > 0 && !isDeleted
    }

    /// Newest-first rows: the current version, earlier revisions, then the
    /// original. `edits` are re-sorted defensively with the same ordering the
    /// projection cache applies, so callers can't change what "current" means.
    static func rows(
        original: AppMessageRecordFfi,
        edits: [AppMessageRecordFfi],
        mentionDisplayName: MarkdownMentionResolver? = nil
    ) -> [Row] {
        let ordered = edits.sorted { lhs, rhs in
            if lhs.recordedAt != rhs.recordedAt {
                return lhs.recordedAt < rhs.recordedAt
            }
            return lhs.messageIdHex < rhs.messageIdHex
        }
        var rows: [Row] = []
        rows.reserveCapacity(ordered.count + 1)
        for (index, edit) in ordered.enumerated().reversed() {
            rows.append(Row(
                id: edit.messageIdHex,
                versionNumber: index + 1,
                body: body(of: edit, mentionDisplayName: mentionDisplayName),
                recordedAt: edit.recordedAt,
                isCurrent: index == ordered.count - 1,
                isOriginal: false
            ))
        }
        rows.append(Row(
            id: original.messageIdHex,
            versionNumber: 0,
            body: body(of: original, mentionDisplayName: mentionDisplayName),
            recordedAt: original.recordedAt,
            isCurrent: ordered.isEmpty,
            isOriginal: true
        ))
        return rows
    }

    static func timestampLabel(
        _ timestamp: UInt64,
        locale: Locale = AppLanguage.currentLocale
    ) -> String? {
        guard timestamp > 0 else { return nil }
        let style = Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)
        return Date(timeIntervalSince1970: TimeInterval(timestamp)).formatted(style)
    }

    private static func body(
        of record: AppMessageRecordFfi,
        mentionDisplayName: MarkdownMentionResolver?
    ) -> String {
        let flattened: String
        if record.contentTokens.blocks.isEmpty {
            flattened = CanonicalMentionDisplayProjection.project(record.plaintext) { npub in
                mentionDisplayName?(MarkdownNostrEntityFfi(hrp: .npub, bech32: npub))
            }.text
        } else {
            flattened = MarkdownPlainText.flatten(
                record.contentTokens,
                mentionDisplayName: mentionDisplayName
            ) ?? record.plaintext
        }
        return ContentSanitizer.compactSingleLine(flattened, maxLength: maxRowBodyLength) ?? ""
    }
}

struct EditHistorySheet: View {
    @Environment(\.dismiss) private var dismiss

    let rows: [EditHistoryPresentation.Row]
    var editCount: UInt64 = 0
    var loadPage: ((TimelineEditVersionFfi?) async throws -> TimelineEditHistoryPageFfi)?
    @State private var loadedRows: [EditHistoryPresentation.Row] = []
    @State private var cursor: TimelineEditVersionFfi?
    @State private var hasMore = false
    @State private var isLoading = false
    @State private var failed = false
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                ForEach(loadPage == nil ? rows : loadedRows) { row in
                    versionCard(row)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowSeparator(.hidden)
                }
                if isLoading { ProgressView() }
                if failed || hasMore {
                    Button(failed ? L10n.string("Retry") : L10n.string("Load more")) {
                        loadTask = Task { await loadNextPage() }
                    }
                    .disabled(isLoading)
                }
            }
            .task { if loadPage != nil { await loadNextPage() } }
            .onDisappear { loadTask?.cancel() }
            .listStyle(.plain)
            .navigationTitle("Edit history")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @MainActor
    private func loadNextPage() async {
        guard let loadPage, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await loadPage(cursor)
            try Task.checkCancellation()
            let offset = loadedRows.count
            let known = Set(loadedRows.map(\.id))
            loadedRows += page.versions.reversed().enumerated().compactMap { index, version in
                guard !known.contains(version.messageIdHex) else { return nil }
                return EditHistoryPresentation.Row(
                    id: version.messageIdHex,
                    versionNumber: max(1, Int(clamping: editCount) - offset - index),
                    body: ContentSanitizer.compactSingleLine(version.plaintext,
                        maxLength: EditHistoryPresentation.maxRowBodyLength) ?? "",
                    recordedAt: version.editedAt, isCurrent: offset == 0 && index == 0,
                    isOriginal: false
                )
            }
            hasMore = page.hasMoreBefore && page.versions.first != nil
            cursor = page.versions.first
            failed = false
        } catch is CancellationError {
            return
        } catch {
            failed = true
        }
    }

    private func versionCard(_ row: EditHistoryPresentation.Row) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                versionLabel(row)
                Spacer(minLength: 8)
                if let timestamp = EditHistoryPresentation.timestampLabel(row.recordedAt) {
                    Text(timestamp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !row.body.isEmpty {
                Text(row.body)
                    .font(.body)
                    .foregroundStyle(row.isCurrent ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func versionLabel(_ row: EditHistoryPresentation.Row) -> some View {
        if row.isCurrent {
            Text("Current")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.tint.opacity(0.18), in: Capsule())
                .foregroundStyle(.tint)
        } else if row.isOriginal {
            Text("Original")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        } else {
            Text(L10n.formatted("Version %lld", Int64(row.versionNumber)))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}
