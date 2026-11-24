import SwiftUI
import MarmotKit

nonisolated enum ForwardMessagePresentation {
    static let maximumDestinationCount = 5

    static func filtered(
        _ destinations: [MessageForwardDestination],
        query: String
    ) -> [MessageForwardDestination] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return destinations }
        return destinations.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
    }
}

struct ForwardMessageSheet: View {
    @Environment(\.dismiss) private var dismiss

    let destinationProvider: () async throws -> [MessageForwardDestination]
    let submit: (Set<String>) async -> MessageForwardResult

    private var sourceIsAvailable: (() async throws -> Bool)?
    @State private var sourceUnavailable = false
    @State private var destinations: [MessageForwardDestination] = []
    @State private var selectedGroupIds = Set<String>()
    @State private var isLoading = true
    @State private var isSending = false
    @State private var loadFailed = false
    @State private var forwardError: LocalizedStringKey?
    @State private var query = ""

    init(
        message: AppMessageRecordFfi,
        viewModel: ConversationViewModel,
        destinationProvider: @escaping () async throws -> [MessageForwardDestination]
    ) {
        self.destinationProvider = destinationProvider
        self.submit = { groupIds in
            await viewModel.forwardMessage(message, to: groupIds)
        }
    }

    init(
        messages: [AppMessageRecordFfi],
        viewModel: ConversationViewModel,
        destinationProvider: @escaping () async throws -> [MessageForwardDestination]
    ) {
        let messages = Array(messages.prefix(MessageSelectionPolicy.maximumForwardCount))
        self.destinationProvider = destinationProvider
        self.submit = { groupIds in
            await viewModel.forwardMessages(messages, to: groupIds)
        }
    }

    init(
        media: MessageMediaAttachment,
        data: Data,
        verifySource: ((MessageMediaAttachment) async throws -> Bool)? = nil,
        viewModel: ConversationViewModel,
        destinationProvider: @escaping () async throws -> [MessageForwardDestination]
    ) {
        self.destinationProvider = destinationProvider
        if let verifySource {
            self.sourceIsAvailable = { try await verifySource(media) }
        }
        self.submit = { groupIds in
            await viewModel.forwardMedia(media, data: data, to: groupIds)
        }
    }

    init(
        media: MessageMediaAttachment,
        fileURL: URL,
        fallbackData: (@MainActor () async throws -> Data)? = nil,
        verifySource: ((MessageMediaAttachment) async throws -> Bool)? = nil,
        viewModel: ConversationViewModel,
        destinationProvider: @escaping () async throws -> [MessageForwardDestination]
    ) {
        self.destinationProvider = destinationProvider
        if let verifySource {
            self.sourceIsAvailable = { try await verifySource(media) }
        }
        self.submit = { groupIds in
            await viewModel.forwardMedia(media, fileURL: fileURL, fallbackData: fallbackData, to: groupIds)
        }
    }

    var body: some View {
        NavigationStack {
            content
                .searchable(text: $query, prompt: "Search Chats")
                .navigationTitle("Forward")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel) { dismiss() }
                            .disabled(isSending)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if !sourceUnavailable { forwardButton }
                }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isSending)
        .task { await loadDestinations() }
    }

    @ViewBuilder
    private var content: some View {
        if sourceUnavailable {
            ContentUnavailableView("Media unavailable", systemImage: "photo.on.rectangle")
        } else if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if loadFailed {
            ContentUnavailableView {
                Label("Couldn't load chats", systemImage: "exclamationmark.triangle")
            } actions: {
                Button("Retry") {
                    Task { await loadDestinations() }
                }
            }
        } else if destinations.isEmpty {
            ContentUnavailableView("No chats yet", systemImage: "bubble.left.and.bubble.right")
        } else if filteredDestinations.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            List(filteredDestinations) { destination in
                Button {
                    toggle(destination.id)
                } label: {
                    HStack(spacing: 12) {
                        AvatarBubble(
                            seed: destination.id,
                            title: destination.title,
                            pictureURL: destination.avatarURL
                        )
                        .frame(width: 42, height: 42)

                        Text(destination.title)
                            .foregroundStyle(.primary)
                            .lineLimit(2)

                        Spacer(minLength: 8)

                        Image(systemName: selectedGroupIds.contains(destination.id)
                              ? "checkmark.circle.fill"
                              : "circle")
                            .font(.title3)
                            .foregroundStyle(selectedGroupIds.contains(destination.id) ? Color.accentColor : .secondary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(
                    isSending
                        || (selectedGroupIds.count == ForwardMessagePresentation.maximumDestinationCount
                            && !selectedGroupIds.contains(destination.id))
                )
                .accessibilityAddTraits(selectedGroupIds.contains(destination.id) ? .isSelected : [])
            }
        }
    }

    private var forwardButton: some View {
        VStack(spacing: 8) {
            if let forwardError {
                Text(forwardError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Button {
                Task { await forward() }
            } label: {
                Group {
                    if isSending {
                        ProgressView()
                            .tint(WNNeutralAccent.foreground)
                    } else {
                        Text("Forward")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 24)
                .foregroundStyle(WNNeutralAccent.foreground)
            }
            .wnPrimaryButtonStyle()
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .disabled(selectedGroupIds.isEmpty || isSending || isLoading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func toggle(_ groupIdHex: String) {
        forwardError = nil
        if selectedGroupIds.contains(groupIdHex) {
            selectedGroupIds.remove(groupIdHex)
        } else if selectedGroupIds.count < ForwardMessagePresentation.maximumDestinationCount {
            selectedGroupIds.insert(groupIdHex)
        }
    }

    private var filteredDestinations: [MessageForwardDestination] {
        ForwardMessagePresentation.filtered(destinations, query: query)
    }

    private func loadDestinations() async {
        isLoading = true
        loadFailed = false
        defer { isLoading = false }
        do {
            destinations = try await destinationProvider()
        } catch {
            loadFailed = true
        }
    }

    private func forward() async {
        guard !isSending, !sourceUnavailable, !selectedGroupIds.isEmpty else { return }
        isSending = true
        defer { isSending = false }
        forwardError = nil
        if let sourceIsAvailable {
            do {
                guard try await sourceIsAvailable() else {
                    sourceUnavailable = true
                    return
                }
            } catch {
                forwardError = "Attachment couldn’t be read"
                return
            }
        }
        let result = await submit(selectedGroupIds)
        if result.succeededCompletely {
            dismiss()
        } else {
            // Successful destinations are removed so Retry cannot duplicate
            // them; only failed sends remain selected.
            selectedGroupIds = result.failedGroupIds
            forwardError = "Send failed"
        }
    }
}

struct EditMessageSheet: View {
    @Environment(\.dismiss) private var dismiss

    let message: AppMessageRecordFfi
    let viewModel: ConversationViewModel

    @State private var draft: String
    @State private var isSaving = false
    @FocusState private var editorFocused: Bool

    init(message: AppMessageRecordFfi, viewModel: ConversationViewModel) {
        self.message = message
        self.viewModel = viewModel
        _draft = State(initialValue: message.plaintext)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $draft)
                        .focused($editorFocused)
                        .frame(minHeight: 160)
                        .onChange(of: draft) { _, value in
                            if value.count > ContentSanitizer.maxMessageLength {
                                draft = String(value.prefix(ContentSanitizer.maxMessageLength))
                            }
                        }
                }
            }
            .navigationTitle("Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .fontWeight(.semibold)
                    .disabled(!canSave)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isSaving)
        .onAppear { editorFocused = true }
    }

    private var canSave: Bool {
        guard !isSaving,
              let normalized = MessageEditingPolicy.normalizedContent(draft)
        else { return false }
        return normalized != message.plaintext
    }

    private func save() async {
        guard canSave else { return }
        isSaving = true
        let succeeded = await viewModel.editMessage(message, content: draft)
        isSaving = false
        if succeeded {
            dismiss()
        }
    }
}
