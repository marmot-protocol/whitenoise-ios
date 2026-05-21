import SwiftUI
import MarmotKit

struct ConversationView: View {
    @Environment(AppState.self) private var appState
    let chat: AppGroupRecordFfi

    @State private var viewModel: ConversationViewModel?
    @State private var draft: String = ""
    @State private var showDetails = false

    private static let quickReactions = ["👍", "❤️", "😂", "🎉", "😮", "😢"]

    var body: some View {
        timeline
            .safeAreaInset(edge: .bottom) { composerArea }
            .navigationTitle(viewModel?.displayTitle ?? chat.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    conversationTitle
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showDetails = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel("Group details")
                }
            }
            .sheet(isPresented: $showDetails) {
                if let viewModel {
                    NavigationStack {
                        GroupDetailsView(viewModel: viewModel)
                    }
                }
            }
            .task {
                if viewModel == nil {
                    viewModel = ConversationViewModel(appState: appState, group: chat)
                }
                await viewModel?.start()
            }
    }

    // MARK: - Composer + reply

    @ViewBuilder
    private var composerArea: some View {
        VStack(spacing: 0) {
            if let viewModel, let replyingTo = viewModel.replyingTo {
                replyBar(for: replyingTo, viewModel: viewModel)
            }
            ComposerBar(
                draft: $draft,
                isSending: viewModel?.sendInFlight ?? false,
                onSend: send
            )
        }
    }

    private func replyBar(for record: AppMessageRecordFfi, viewModel: ConversationViewModel) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.accentColor)
                .frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Replying to \(appState.displayName(forAccountIdHex: record.sender))")
                    .font(.caption.weight(.semibold))
                Text(ProfileSanitizer.singleLine(viewModel.displayBody(of: record), maxLength: 100) ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                viewModel.replyingTo = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }

    @ViewBuilder
    private var conversationTitle: some View {
        if let viewModel {
            VStack(spacing: 0) {
                Text(viewModel.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(viewModel.displaySubtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else {
            Text(chat.name)
                .font(.headline)
        }
    }

    // MARK: - Timeline

    @ViewBuilder
    private var timeline: some View {
        if let viewModel {
            if viewModel.timeline.isEmpty {
                ContentUnavailableView(
                    "No messages yet",
                    systemImage: "bubble.middle.bottom",
                    description: Text("Send the first message to get started.")
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(viewModel.timeline) { item in
                                row(for: item, viewModel: viewModel)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .onChange(of: viewModel.timeline.last?.id) { _, newId in
                        guard let newId else { return }
                        withAnimation(.smooth(duration: 0.2)) {
                            proxy.scrollTo(newId, anchor: .bottom)
                        }
                    }
                    .onAppear {
                        if let last = viewModel.timeline.last?.id {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func row(for item: TimelineItem, viewModel: ConversationViewModel) -> some View {
        switch item.kind {
        case .message(let record, let status):
            MessageBubble(
                record: record,
                status: status,
                replyPreview: viewModel.replyPreview(for: record),
                reactions: viewModel.reactions(for: record.messageIdHex),
                onTapReaction: { emoji in
                    Task { await viewModel.toggleReaction(emoji, on: record) }
                }
            )
            .id(item.id)
            .contextMenu { messageMenu(for: record, viewModel: viewModel) }
            .gesture(replySwipe(for: record, viewModel: viewModel))
        case .systemEvent(let event):
            SystemEventRow(event: event)
                .id(item.id)
        }
    }

    @ViewBuilder
    private func messageMenu(for record: AppMessageRecordFfi, viewModel: ConversationViewModel) -> some View {
        // Reactions can only target a confirmed (server-assigned) message.
        if !record.messageIdHex.isEmpty {
            ControlGroup {
                ForEach(Self.quickReactions, id: \.self) { emoji in
                    Button(emoji) {
                        Task { await viewModel.toggleReaction(emoji, on: record) }
                    }
                }
            }
        }
        Button {
            viewModel.replyingTo = record
        } label: {
            Label("Reply", systemImage: "arrowshape.turn.up.left")
        }
    }

    /// Lightweight swipe-right-to-reply. Fires only on release for a clearly
    /// horizontal drag, so it doesn't fight the scroll view.
    private func replySwipe(for record: AppMessageRecordFfi, viewModel: ConversationViewModel) -> some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                if value.translation.width > 60,
                   abs(value.translation.width) > abs(value.translation.height) {
                    Haptics.tap()
                    viewModel.replyingTo = record
                }
            }
    }

    private func send() {
        let text = draft
        draft = ""
        Task {
            await viewModel?.send(text)
        }
    }
}
