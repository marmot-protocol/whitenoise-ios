import SwiftUI
import MarmotKit

struct ConversationView: View {
    @Environment(AppState.self) private var appState
    let chat: AppGroupRecordFfi

    @State private var viewModel: ConversationViewModel?
    @State private var draft: String = ""
    @State private var showDetails = false

    var body: some View {
        VStack(spacing: 0) {
            timeline
            Divider()
            ComposerBar(
                draft: $draft,
                isSending: viewModel?.sendInFlight ?? false,
                onSend: send
            )
        }
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
                                switch item.kind {
                                case .message(let record, let status):
                                    MessageBubble(record: record, status: status)
                                        .id(item.id)
                                case .systemEvent(let event):
                                    SystemEventRow(event: event)
                                        .id(item.id)
                                }
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

    private func send() {
        let text = draft
        draft = ""
        Task {
            await viewModel?.send(text)
        }
    }
}
