import Combine
import SwiftUI

nonisolated struct EmojiCatalogEntry: Codable, Identifiable, Hashable {
    let emoji: String
    let name: String
    let group: Int
    let keywords: [String]
    let nameLowercased: String
    let keywordsLowercased: [String]

    var id: String { emoji }

    enum CodingKeys: String, CodingKey {
        case emoji = "e"
        case name = "n"
        case group = "g"
        case keywords = "k"
    }

    init(emoji: String, name: String, group: Int, keywords: [String]) {
        self.emoji = emoji
        self.name = name
        self.group = group
        self.keywords = keywords
        nameLowercased = name.lowercased()
        keywordsLowercased = keywords.map { $0.lowercased() }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            emoji: try container.decode(String.self, forKey: .emoji),
            name: try container.decode(String.self, forKey: .name),
            group: try container.decode(Int.self, forKey: .group),
            keywords: try container.decode([String].self, forKey: .keywords)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(emoji, forKey: .emoji)
        try container.encode(name, forKey: .name)
        try container.encode(group, forKey: .group)
        try container.encode(keywords, forKey: .keywords)
    }
}

nonisolated enum EmojiCatalogSearch {
    static func results(in entries: [EmojiCatalogEntry], query: String, limit: Int = 120) -> [EmojiCatalogEntry] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return entries }

        return entries.compactMap { entry -> (EmojiCatalogEntry, Int)? in
            var score = 0
            for term in terms {
                if entry.nameLowercased == term {
                    score += 100
                } else if entry.nameLowercased.hasPrefix(term) {
                    score += 60
                } else if entry.nameLowercased.contains(term) {
                    score += 35
                } else if entry.keywordsLowercased.contains(term) {
                    score += 25
                } else if entry.keywordsLowercased.contains(where: { $0.hasPrefix(term) }) {
                    score += 12
                } else {
                    return nil
                }
            }
            return (entry, score)
        }
        .sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.name < $1.0.name
        }
        .prefix(limit)
        .map(\.0)
    }
}

private struct EmojiCategory: Identifiable {
    let id: Int
    let title: LocalizedStringKey
    let systemImage: String

    static let all = [
        Self(id: 0, title: "Smileys & People", systemImage: "face.smiling"),
        Self(id: 1, title: "People & Body", systemImage: "person.fill"),
        Self(id: 2, title: "Animals & Nature", systemImage: "pawprint.fill"),
        Self(id: 3, title: "Food & Drink", systemImage: "fork.knife"),
        Self(id: 4, title: "Travel & Places", systemImage: "car.fill"),
        Self(id: 5, title: "Activities", systemImage: "soccerball"),
        Self(id: 6, title: "Objects", systemImage: "lightbulb.fill"),
        Self(id: 7, title: "Symbols", systemImage: "heart.fill"),
        Self(id: 8, title: "Flags", systemImage: "flag.fill")
    ]
}

@MainActor
private final class EmojiPickerModel: ObservableObject {
    @Published private(set) var entries: [EmojiCatalogEntry] = []
    @Published private(set) var didFail = false

    func load() async {
        guard entries.isEmpty else { return }
        guard let url = Bundle.main.url(forResource: "emoji", withExtension: "json") else {
            didFail = true
            return
        }
        do {
            entries = try await Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                return try JSONDecoder().decode([EmojiCatalogEntry].self, from: data)
            }.value
        } catch {
            didFail = true
        }
    }
}

private enum EmojiRecents {
    static let key = "chat.emoji-picker.recents"
    static let maximumCount = 40

    static var values: [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? AppState.defaultReactions
    }

    static func record(_ emoji: String) {
        var result = values.filter { $0 != emoji }
        result.insert(emoji, at: 0)
        UserDefaults.standard.set(Array(result.prefix(maximumCount)), forKey: key)
    }
}

struct EmojiPickerSheet: View {
    var quickReactions: [String]?
    var onQuickReactionsSave: (([String]) -> Void)?
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isConfiguringReactions = false

    var body: some View {
        EmojiPickerContent(
            showsSearchField: true,
            onConfigure: quickReactions != nil && onQuickReactionsSave != nil
                ? { isConfiguringReactions = true }
                : nil
        ) { emoji in
            onPick(emoji)
            dismiss()
        }
        .accessibilityAction(.escape) { dismiss() }
        .sheet(isPresented: $isConfiguringReactions) {
            if let quickReactions, let onQuickReactionsSave {
                NavigationStack {
                    QuickReactionEditorView(
                        quickReactions: quickReactions,
                        onSave: onQuickReactionsSave
                    )
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct QuickReactionEditorView: View {
    let onSave: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: [String]
    @State private var editingIndex: Int?

    init(
        quickReactions: [String],
        onSave: @escaping ([String]) -> Void
    ) {
        self.onSave = onSave
        _draft = State(initialValue: QuickReactionChoices.normalize(quickReactions))
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            HStack(spacing: 0) {
                ForEach(Array(draft.enumerated()), id: \.offset) { index, emoji in
                    Button {
                        editingIndex = index
                    } label: {
                        Text(emoji)
                            .font(.system(size: 32))
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.formatted("Change quick reaction %lld", Int64(index + 1)))
                }
            }
            .padding(6)
            .frame(maxWidth: 360)
            .background(.regularMaterial, in: .capsule)
            .overlay {
                Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }

            Text("Tap a reaction to replace it. These six reactions appear first when you open message actions.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()
            Spacer()
        }
        .padding()
        .navigationTitle("Customize reactions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Reset") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        draft = AppState.defaultReactions
                    }
                }
                .disabled(draft == AppState.defaultReactions)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", systemImage: "checkmark") {
                    onSave(draft)
                    dismiss()
                }
            }
        }
        .navigationDestination(
            isPresented: Binding(
                get: { editingIndex != nil },
                set: { if !$0 { editingIndex = nil } }
            )
        ) {
            EmojiPickerContent(showsSearchField: true) { emoji in
                guard let editingIndex, draft.indices.contains(editingIndex) else { return }
                draft = QuickReactionChoices.replacing(draft, at: editingIndex, with: emoji)
                self.editingIndex = nil
            }
            .navigationTitle("Choose reaction")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct ComposerEmojiPanel: View {
    let onPick: (String) -> Void
    let onDeleteBackward: () -> Void

    var body: some View {
        EmojiPickerContent(
            showsSearchField: false,
            onDeleteBackward: onDeleteBackward,
            onPick: onPick
        )
        .background(Color(.systemBackground))
    }
}

private struct EmojiPickerContent: View {
    let showsSearchField: Bool
    var onConfigure: (() -> Void)?
    var onDeleteBackward: (() -> Void)?
    let onPick: (String) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var model = EmojiPickerModel()
    @State private var query = ""
    @State private var selectedCategory = 0

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if showsSearchField {
                    HStack(spacing: 4) {
                        searchField
                        if let onConfigure {
                            Button(action: onConfigure) {
                                Image(systemName: "gearshape")
                                    .frame(width: 44, height: 44)
                                    .background(.regularMaterial, in: .circle)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Customize reactions")
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                }
                emojiGrid
                Divider()
                categoryRail(proxy: proxy)
            }
        }
        .task { await model.load() }
    }

    private var searchField: some View {
        WNInput(
            placeholder: L10n.string("Search emoji"),
            text: $query,
            icon: "magnifyingglass",
            fill: Color(.secondarySystemBackground),
            submitLabel: .search,
            showsClear: true,
            clearLabel: L10n.string("Clear search")
        )
    }

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: 4),
            count: dynamicTypeSize.isAccessibilitySize ? 6 : 8
        )
    }

    @ViewBuilder
    private var emojiGrid: some View {
        if model.entries.isEmpty, !model.didFail {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.didFail {
            ContentUnavailableView(
                L10n.string("Emoji unavailable"),
                systemImage: "face.dashed",
                description: Text(L10n.string("The emoji catalog could not be loaded."))
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12, pinnedViews: [.sectionHeaders]) {
                    if !query.isEmpty {
                        emojiSection(title: "Search results", entries: searchResults)
                    } else {
                        let recentEntries = EmojiRecents.values.compactMap { emoji in
                            model.entries.first { $0.emoji == emoji }
                        }
                        if !recentEntries.isEmpty {
                            emojiSection(title: "Recently used", entries: recentEntries)
                                .id("recent")
                        }
                        ForEach(EmojiCategory.all) { category in
                            emojiSection(
                                title: category.title,
                                entries: model.entries.filter { $0.group == category.id }
                            )
                            .id("category-\(category.id)")
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
        }
    }

    private var searchResults: [EmojiCatalogEntry] {
        EmojiCatalogSearch.results(in: model.entries, query: query)
    }

    private func emojiSection(
        title: LocalizedStringKey,
        entries: [EmojiCatalogEntry]
    ) -> some View {
        Section {
            LazyVGrid(columns: columns, spacing: 5) {
                ForEach(entries) { entry in
                    Button {
                        EmojiRecents.record(entry.emoji)
                        onPick(entry.emoji)
                    } label: {
                        Text(entry.emoji)
                            .font(.system(size: 29))
                            .frame(maxWidth: .infinity, minHeight: 42)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(entry.name)
                }
            }
        } header: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 7)
                .background(.bar)
        }
    }

    private func categoryRail(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    railButton(systemImage: "clock.fill", selected: false) {
                        withAnimation(.smooth) { proxy.scrollTo("recent", anchor: .top) }
                    }
                    ForEach(EmojiCategory.all) { category in
                        railButton(systemImage: category.systemImage, selected: selectedCategory == category.id) {
                            selectedCategory = category.id
                            withAnimation(.smooth) { proxy.scrollTo("category-\(category.id)", anchor: .top) }
                        }
                        .accessibilityLabel(Text(category.title))
                    }
                }
                .padding(4)
            }
            if let onDeleteBackward {
                Divider()
                    .frame(height: 30)
                Button(action: onDeleteBackward) {
                    Image(systemName: "delete.left.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 46, height: 46)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.string("Delete"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: .capsule)
        .padding(.horizontal, 8)
    }

    private func railButton(
        systemImage: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .frame(width: 38, height: 36)
                .background(selected ? Color(.tertiarySystemFill) : .clear, in: .circle)
        }
        .buttonStyle(.plain)
    }
}
