import SwiftUI
import MarmotKit

/// Full-width actions overlay shown when long-pressing a message: a single
/// row of the most-recent reaction emojis with a full-picker button, then
/// Reply, then Delete (own messages only).
struct MessageActionsSheet: View {
    let isMine: Bool
    let quickReactions: [String]
    let onReact: (String) -> Void
    let onReply: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void

    @State private var showPicker = false

    var body: some View {
        VStack(spacing: 0) {
            reactionRow
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 6)

            Divider()

            actionRow("Reply", systemImage: "arrowshape.turn.up.left", action: onReply)
            Divider().padding(.leading, 52)
            actionRow("Copy", systemImage: "doc.on.doc", action: onCopy)

            if isMine {
                Divider().padding(.leading, 52)
                actionRow("Delete", systemImage: "trash", role: .destructive, action: onDelete)
            }

            Spacer(minLength: 0)
        }
        .presentationDetents([.height(isMine ? 290 : 230)])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showPicker) {
            EmojiPickerSheet(onPick: onReact)
        }
    }

    private var reactionRow: some View {
        HStack(spacing: 18) {
            ForEach(quickReactions, id: \.self) { emoji in
                Button {
                    onReact(emoji)
                } label: {
                    Text(emoji).font(.title)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 8)
            Divider().frame(height: 30)
            Button {
                showPicker = true
            } label: {
                Image(systemName: "face.smiling")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More emoji")
        }
    }

    private func actionRow(
        _ title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .frame(width: 24)
                Text(title)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .contentShape(.rect)
        }
        .foregroundStyle(role == .destructive ? Color.red : Color.primary)
    }
}

/// A simple curated emoji grid used as the "full picker" from the actions row.
struct EmojiPickerSheet: View {
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private static let emojis: [String] = [
        "👍", "👎", "❤️", "🔥", "🎉", "😂", "🤣", "😅", "😊", "😍",
        "😎", "🤔", "🙏", "👏", "🙌", "💪", "🤝", "👀", "😮", "😯",
        "😢", "😭", "😡", "🤯", "🥳", "😴", "🥲", "💯", "✅", "❌",
        "⭐️", "🌟", "💜", "💙", "💚", "🧡", "🤍", "🖤", "💔", "✨",
        "🚀", "👋", "🤙", "🫡", "🫶", "😬", "😇", "🤩", "🥹", "😆"
    ]

    private let columns = Array(repeating: GridItem(.flexible()), count: 6)

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(Self.emojis, id: \.self) { emoji in
                        Button {
                            onPick(emoji)
                            dismiss()
                        } label: {
                            Text(emoji).font(.largeTitle)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .navigationTitle("React")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
