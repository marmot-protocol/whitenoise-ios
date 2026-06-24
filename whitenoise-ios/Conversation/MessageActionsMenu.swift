import SwiftUI
import MarmotKit

/// Free-floating actions pane shown in a popover anchored under a long-pressed
/// message: a row of the most-recent reaction emojis with a full-picker
/// button, then Reply, Copy, and Delete (own messages only).
struct MessageActionsMenu: View {
    let isMine: Bool
    let quickReactions: [String]
    let onReact: (String) -> Void
    let onReply: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void
    let onMoreEmoji: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            reactionRow
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            Divider()

            actionRow("Reply", systemImage: "arrowshape.turn.up.left", action: onReply)
            Divider().padding(.leading, 46)
            actionRow("Copy", systemImage: "doc.on.doc", action: onCopy)

            if isMine {
                Divider().padding(.leading, 46)
                actionRow("Delete", systemImage: "trash", role: .destructive, action: onDelete)
            }
        }
        .frame(width: 280)
        .presentationCompactAdaptation(.popover)
    }

    private var reactionRow: some View {
        HStack(spacing: 12) {
            ForEach(quickReactions, id: \.self) { emoji in
                Button {
                    onReact(emoji)
                } label: {
                    Text(emoji).font(.title3)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 4)
            Divider().frame(height: 26)
            Button {
                onMoreEmoji()
            } label: {
                Image(systemName: "face.smiling")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More emoji")
        }
    }

    private func actionRow(
        _ title: LocalizedStringKey,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .frame(width: 22)
                Text(title)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(.rect)
        }
        .foregroundStyle(role == .destructive ? Color.red : Color.primary)
    }
}

/// A simple curated emoji grid used as the "full picker" from the actions row.
struct EmojiPickerSheet: View {
    var title: LocalizedStringKey? = "React"
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                LazyVGrid(columns: EmojiPickerPresentation.columns, spacing: 16) {
                    ForEach(EmojiPickerPresentation.options) { option in
                        Button {
                            onPick(option.emoji)
                            dismiss()
                        } label: {
                            Text(option.emoji)
                                .font(.largeTitle)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var header: some View {
        HStack {
            if let title {
                Text(title)
                    .font(.headline)
            } else {
                Spacer(minLength: 0)
            }

            Spacer(minLength: 16)

            Button("Done") { dismiss() }
                .buttonStyle(.plain)
                .font(.headline)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

enum EmojiPickerPresentation {
    static let columnCount = 6
    static let columns = Array(
        repeating: GridItem(.flexible(minimum: 36), spacing: 12),
        count: columnCount
    )
    static let options: [EmojiPickerOption] = [
        "👍", "👎", "❤️", "🔥", "🎉", "😂", "🤣", "😅", "😊", "😍",
        "😎", "🤔", "🙏", "👏", "🙌", "💪", "🤝", "👀", "😮", "😯",
        "😢", "😭", "😡", "🤯", "🥳", "😴", "🥲", "💯", "✅", "❌",
        "⭐️", "🌟", "💜", "💙", "💚", "🧡", "🤍", "🖤", "💔", "✨",
        "🚀", "👋", "🤙", "🫡", "🫶", "😬", "😇", "🤩", "🥹", "😆"
    ].map(EmojiPickerOption.init)
}

struct EmojiPickerOption: Identifiable, Hashable {
    let emoji: String

    var id: String { emoji }
}
