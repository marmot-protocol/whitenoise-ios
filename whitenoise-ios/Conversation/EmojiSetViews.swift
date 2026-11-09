import MarmotKit
import SwiftUI
import UIKit

extension EnvironmentValues {
    /// Decoded emoji-set images for pickers and the set browser.
    @Entry var emojiSetImages: EmojiSetImageStore?
}

/// One emoji-set image: an installed emoji from MDK's local store, or a
/// preview of an opened set. A failed preview offers an explicit retry.
struct EmojiSetImage<Placeholder: View>: View {
    @Environment(\.displayScale) private var displayScale

    let source: EmojiSetImageStore.Source
    let store: EmojiSetImageStore?
    let pointSize: CGFloat
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var image: UIImage?
    @State private var failed = false

    private struct LoadID: Equatable {
        let source: EmojiSetImageStore.Source
        let pixelSize: Int
        let hasStore: Bool
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: pointSize, height: pointSize)
            } else if failed, case .preview = source {
                Button {
                    Task { await load(retry: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(.secondary)
                        .frame(width: pointSize, height: pointSize)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.string("Try Again"))
            } else {
                placeholder()
            }
        }
        .task(id: LoadID(source: source, pixelSize: pixelSize, hasStore: store != nil)) {
            await load(retry: false)
        }
    }

    private var pixelSize: Int {
        CustomEmojiInlineMetrics.pixelSize(pointSize: pointSize, scale: displayScale)
    }

    private func load(retry: Bool) async {
        guard let store else { return }
        if let cached = store.cached(source, pixelSize: pixelSize) {
            image = cached
            return
        }
        failed = false
        let loaded = retry
            ? await store.retry(source, pixelSize: pixelSize, scale: displayScale)
            : await store.image(for: source, pixelSize: pixelSize, scale: displayScale)
        guard !Task.isCancelled else { return }
        image = loaded
        failed = loaded == nil
    }
}

private struct EmojiSetEgressDisclosure: View {
    var body: some View {
        Text(L10n.string("Emoji sets are public and aren’t reviewed by White Noise. Opening or installing a set downloads its images from servers its author chose, which can see your IP address. Installing doesn’t change your public emoji list."))
    }
}

// MARK: - Browsing

struct EmojiSetBrowserView: View {
    let library: EmojiSetLibrary

    @State private var search = ""
    @State private var link = ""
    @State private var discovered: [EmojiSetFfi] = []
    @State private var suggestions: [EmojiSetFfi] = []
    @State private var isLoading = false
    @State private var syncError: String?
    @State private var isLookingUp = false
    @State private var lookedUp: EmojiSetFfi?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                TextField(L10n.string("Emoji set address"), text: $link)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .onSubmit(lookUp)
                Button(L10n.string("Open Link"), action: lookUp)
                    .disabled(EmojiSetPresentation.lookupInput(link) == nil || isLookingUp)
            } header: {
                Text(L10n.string("Add by Link"))
            } footer: {
                Text(L10n.string("Paste an emoji set’s naddr or address."))
            }

            if !library.installedSets.isEmpty {
                Section(L10n.string("Installed")) {
                    ForEach(library.installedSets, id: \.coordinate) { set in
                        NavigationLink {
                            EmojiSetDetailView(library: library, set: set)
                        } label: {
                            EmojiSetRow(set: set, progress: library.installProgress[set.coordinate])
                        }
                    }
                    .onDelete(perform: uninstall)
                }
            }

            let pendingSuggestions = suggestions.filter { !library.isInstalled($0.coordinate) }
            if !pendingSuggestions.isEmpty {
                Section {
                    ForEach(pendingSuggestions, id: \.coordinate) { set in
                        NavigationLink {
                            EmojiSetDetailView(library: library, set: set)
                        } label: {
                            EmojiSetRow(set: set, progress: library.installProgress[set.coordinate])
                        }
                    }
                } header: {
                    Text(L10n.string("From Your Emoji List"))
                } footer: {
                    Text(L10n.string("Sets your public Nostr emoji list includes."))
                }
            }

            Section {
                let shown = discovered.filter { !library.isInstalled($0.coordinate) }
                switch StickerPackPresentation.discoveryState(
                    isLoading: isLoading, packCount: shown.count, search: search, syncError: syncError) {
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity)
                case .packs:
                    ForEach(shown, id: \.coordinate) { set in
                        NavigationLink {
                            EmojiSetDetailView(library: library, set: set)
                        } label: {
                            EmojiSetRow(set: set, progress: library.installProgress[set.coordinate])
                        }
                    }
                case .noneOnRelays:
                    Text(L10n.string("Your relays don’t have any emoji sets yet. Paste a set’s address above to add one."))
                        .foregroundStyle(.secondary)
                case .noMatches:
                    Text(L10n.string("No emoji sets match your search."))
                        .foregroundStyle(.secondary)
                case .unreachable(let message):
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.string("Couldn’t check your relays for emoji sets."))
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button(L10n.string("Try Again")) {
                            Task { await reloadDiscovered(debounce: false, forceSync: true) }
                        }
                    }
                }
            } header: {
                Text(L10n.string("Discover"))
            } footer: {
                EmojiSetEgressDisclosure()
            }
        }
        .navigationTitle(L10n.string("Emoji Sets"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: L10n.string("Search emoji sets or paste an npub"))
        .task { await library.loadInstalledIfNeeded() }
        .task { await loadSuggestions() }
        .task(id: search) { await reloadDiscovered(debounce: !search.isEmpty) }
        .refreshable {
            await reloadDiscovered(debounce: false, forceSync: true)
            await loadSuggestions()
        }
        .navigationDestination(item: $lookedUp) { set in
            EmojiSetDetailView(library: library, set: set)
        }
        .alert(L10n.string("Emoji Sets"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(L10n.string("OK"), role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// Text only. A failure leaves the section hidden; Discover still works.
    private func loadSuggestions() async {
        guard let sets = try? await library.suggestions() else { return }
        suggestions = sets
    }

    private func reloadDiscovered(debounce: Bool, forceSync: Bool = false) async {
        if debounce {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
        }
        isLoading = true
        defer { isLoading = false }
        do {
            do {
                try await library.sync(force: forceSync, search: search)
                syncError = nil
            } catch is CancellationError {
                return
            } catch {
                syncError = UserFacingError.message(for: error)
            }
            let sets = try await library.discover(search: search)
            guard !Task.isCancelled else { return }
            discovered = sets
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = UserFacingError.message(for: error)
        }
    }

    private func lookUp() {
        guard let input = EmojiSetPresentation.lookupInput(link), !isLookingUp else { return }
        isLookingUp = true
        Task {
            defer { isLookingUp = false }
            do {
                lookedUp = try await library.lookUp(input)
                link = ""
            } catch is CancellationError {
                return
            } catch {
                errorMessage = UserFacingError.message(for: error)
            }
        }
    }

    private func uninstall(at offsets: IndexSet) {
        let coordinates = offsets.map { library.installedSets[$0].coordinate }
        Task {
            for coordinate in coordinates {
                do {
                    try await library.uninstall(coordinate)
                } catch is CancellationError {
                    return
                } catch {
                    errorMessage = UserFacingError.message(for: error)
                    return
                }
            }
        }
    }
}

/// A set as text only: its images load once the set is opened.
private struct EmojiSetRow: View {
    let set: EmojiSetFfi
    let progress: EmojiSetInstallProgressFfi?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "face.smiling")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: EmojiSetPresentation.title(set))
                    .font(.body)
                    .lineLimit(1)
                Text(EmojiSetPresentation.summary(set))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let progress {
                    ProgressView(value: EmojiSetPresentation.fraction(progress) ?? 0)
                        .accessibilityLabel(L10n.string("Installing"))
                } else if set.installed?.updateAvailable == true {
                    Text(L10n.string("Update available"))
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - One set

struct EmojiSetDetailView: View {
    let library: EmojiSetLibrary

    @State private var set: EmojiSetFfi
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var confirmingRemove = false
    @ScaledMetric(relativeTo: .title) private var cellSize: CGFloat = 44

    init(library: EmojiSetLibrary, set: EmojiSetFfi) {
        self.library = library
        _set = State(initialValue: set)
    }

    private var isInstalled: Bool { library.isInstalled(set.coordinate) }
    private var progress: EmojiSetInstallProgressFfi? { library.installProgress[set.coordinate] }
    private var action: EmojiSetPresentation.Action { EmojiSetPresentation.action(for: set, isInstalled: isInstalled) }

    /// Emoji this device already stored, by shortcode, read locally instead
    /// of contacting the image host.
    private var installedShortcodes: [String: InstalledCustomEmojiFfi] {
        guard isInstalled, set.installed?.updateAvailable != true else { return [:] }
        return Dictionary(library.currentInstalledEmoji.filter { $0.setCoordinate == set.coordinate }.map { ($0.shortcode, $0) },
                          uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(EmojiSetPresentation.summary(set))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(L10n.formatted("By %@", IdentityPresentation.text(accountIdHex: set.authorPubkeyHex)))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let description = EmojiSetPresentation.description(set) {
                    Text(verbatim: description)
                        .font(.body)
                }
                notes
                if let progress {
                    installProgress(progress)
                }
                grid
                EmojiSetEgressDisclosure()
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if isInstalled, action == .update {
                    Button(L10n.string("Remove Set"), role: .destructive) { confirmingRemove = true }
                        .disabled(isWorking || progress != nil)
                }
            }
            .padding(16)
        }
        .navigationTitle(Text(verbatim: EmojiSetPresentation.title(set)))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isWorking || progress != nil {
                    ProgressView()
                } else {
                    switch action {
                    case .install:
                        Button(L10n.string("Install")) { perform(.install) }
                    case .update:
                        Button(L10n.string("Update")) { perform(.update) }
                    case .remove:
                        Button(L10n.string("Remove"), role: .destructive) { confirmingRemove = true }
                    }
                }
            }
        }
        .confirmationDialog(
            L10n.string("Remove this emoji set?"),
            isPresented: $confirmingRemove,
            titleVisibility: .visible
        ) {
            Button(L10n.string("Remove"), role: .destructive) { perform(.remove) }
        } message: {
            Text(L10n.string("Its emoji leave your picker. Messages you already sent keep them."))
        }
        .alert(Text(verbatim: EmojiSetPresentation.title(set)), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(L10n.string("OK"), role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var notes: some View {
        if let skipped = EmojiSetPresentation.skippedNote(set) {
            Label(skipped, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        let unsendable = EmojiSetPresentation.unsendableCount(set)
        if unsendable > 0 {
            Label(L10n.plural("%lld emoji have names chats can’t send, so they won’t appear in your picker.",
                              Int64(unsendable)),
                  systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func installProgress(_ progress: EmojiSetInstallProgressFfi) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let fraction = EmojiSetPresentation.fraction(progress) {
                ProgressView(value: fraction)
            } else {
                ProgressView()
            }
            HStack {
                Text(L10n.formatted("Installing %lld of %lld", Int64(progress.completedEmoji), Int64(progress.totalEmoji)))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button(L10n.string("Cancel")) { library.cancelInstall(set.coordinate) }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var grid: some View {
        let installed = installedShortcodes
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: cellSize + 12), spacing: 8)], spacing: 12) {
            ForEach(set.emoji, id: \.shortcode) { entry in
                VStack(spacing: 4) {
                    EmojiSetImage(source: source(for: entry, installed: installed), store: library.images,
                                  pointSize: cellSize) {
                        ProgressView()
                            .frame(width: cellSize, height: cellSize)
                    }
                    Text(verbatim: entry.shortcode)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                // `.combine` keeps a failed preview's retry button actionable.
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(verbatim: entry.shortcode))
            }
        }
    }

    private func source(for entry: EmojiSetEmojiFfi, installed: [String: InstalledCustomEmojiFfi]) -> EmojiSetImageStore.Source {
        if let stored = installed[entry.shortcode] {
            return .installed(coordinate: stored.setCoordinate, shortcode: stored.shortcode, sha256: stored.sha256)
        }
        return .preview(coordinate: set.coordinate, eventIdHex: set.eventIdHex, shortcode: entry.shortcode)
    }

    private func perform(_ action: EmojiSetPresentation.Action) {
        guard !isWorking else { return }
        isWorking = true
        let shown = set
        Task {
            defer { isWorking = false }
            do {
                switch action {
                case .install, .update:
                    isWorking = false
                    let result = try await library.install(shown)
                    set = result.set
                    if !result.skipped.isEmpty {
                        errorMessage = L10n.plural("%lld emoji couldn’t be installed.", Int64(result.skipped.count))
                    }
                case .remove:
                    try await library.uninstall(shown.coordinate)
                    if let current = try? await library.current(shown.coordinate) { set = current }
                }
            } catch {
                if EmojiSetPresentation.isCancellation(error) { return }
                if EmojiSetPresentation.changedVersion(error) != nil,
                   let current = try? await library.current(shown.coordinate) {
                    set = current
                }
                errorMessage = UserFacingError.message(for: error)
            }
        }
    }
}
