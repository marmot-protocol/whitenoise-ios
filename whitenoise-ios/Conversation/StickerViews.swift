import SwiftUI
import MarmotKit

extension EnvironmentValues {
    @Entry var stickerAssets: StickerAssetStore? = nil
    @Entry var stickerLibrary: StickerLibrary? = nil
}

nonisolated enum StickerMetrics {
    static let messageSide: CGFloat = 150
    static let gridMinimum: CGFloat = 76
    static let packTabSide: CGFloat = 36
}

/// One sticker image. Loads by itself only when `loadsAutomatically`;
/// otherwise a tap loads it, since loading contacts the pack's server.
struct StickerImage: View {
    let sticker: StickerKey
    let loadsAutomatically: Bool
    var placeholderLabel: String?

    @Environment(\.stickerAssets) private var store
    @State private var loaded: StickerAssetStore.Loaded?
    @State private var phase = Phase.idle
    @State private var explicitRequests = 0

    private enum Phase { case idle, loading, waitingForTap, failed }

    private struct TaskID: Equatable {
        let sticker: StickerKey
        let automatic: Bool
        let explicitRequests: Int
    }

    var body: some View {
        Group {
            if let loaded {
                Image(uiImage: loaded.image)
                    .resizable()
                    .scaledToFit()
            } else {
                placeholder
            }
        }
        // `.combine` keeps the Load/Retry button's action; `.ignore` would drop it.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(StickerLoadPolicy.accessibilityLabel(alt: loaded?.sticker.alt, emoji: loaded?.sticker.emoji))
        .task(id: TaskID(sticker: sticker, automatic: loadsAutomatically, explicitRequests: explicitRequests)) {
            await load()
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        switch phase {
        case .waitingForTap, .failed:
            Button {
                explicitRequests += 1
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: phase == .failed ? "exclamationmark.triangle" : "face.dashed")
                        .font(.title2)
                    Text(phase == .failed ? L10n.string("Tap to retry") : (placeholderLabel ?? L10n.string("Tap to load")))
                        .font(.caption)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(shape.fill(Color(.secondarySystemFill)))
                .contentShape(shape)
            }
            .buttonStyle(.plain)
            .accessibilityHint(L10n.string("Loads the sticker from the server its pack uses."))
        case .idle, .loading:
            shape.fill(Color(.secondarySystemFill))
                .overlay { if phase == .loading { ProgressView() } }
        }
    }

    private func load() async {
        guard let store else { return }
        if let cached = store.cached(sticker) {
            loaded = cached
            return
        }
        loaded = nil
        let explicit = explicitRequests > 0
        guard loadsAutomatically || explicit else {
            phase = .waitingForTap
            return
        }
        if store.hasFailed(sticker), !explicit {
            phase = .failed
            return
        }
        phase = .loading
        let result = explicit ? await store.retry(sticker) : await store.image(for: sticker)
        guard !Task.isCancelled else { return }
        loaded = result
        phase = result == nil ? .failed : .idle
    }
}

/// A sticker message: the image alone, without a bubble.
struct StickerMessageContent: View {
    let sticker: StickerKey
    let isFromMe: Bool

    @Environment(\.stickerLibrary) private var library

    var body: some View {
        StickerImage(
            sticker: sticker,
            loadsAutomatically: StickerLoadPolicy.loadsAutomatically(
                isFromMe: isFromMe,
                packInstalled: library?.isInstalled(sticker.packCoordinate) ?? false,
                autoDownloadImages: MediaAutoDownloadStore.shared.shouldAutoDownload(.image)
            ),
            placeholderLabel: L10n.string("Tap to load sticker")
        )
        .frame(width: StickerMetrics.messageSide, height: StickerMetrics.messageSide)
        .task { await library?.loadInstalledIfNeeded() }
    }
}

// MARK: - Picker

/// The composer's sticker picker: installed packs as tabs over a grid.
/// Tapping a sticker sends it.
struct StickerPickerSheet: View {
    let library: StickerLibrary
    let onSend: (StickerFfi) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedPack: String?
    @State private var showsBrowser = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(L10n.string("Stickers"))
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(isPresented: $showsBrowser) {
                    StickerPackBrowserView(library: library)
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.string("Cancel")) { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        NavigationLink {
                            StickerPackBrowserView(library: library)
                        } label: {
                            Label(L10n.string("Sticker Packs"), systemImage: "plus")
                        }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .task {
            await library.loadInstalledIfNeeded()
            try? await library.sync()
        }
    }

    private var currentPack: StickerPackFfi? {
        library.installed.first { $0.coordinate == selectedPack } ?? library.installed.first
    }

    @ViewBuilder
    private var content: some View {
        if !library.hasLoadedInstalled {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let pack = currentPack {
            VStack(spacing: 0) {
                if library.installed.count > 1 { packTabs }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(StickerPackPresentation.title(pack))
                            .font(.subheadline.weight(.semibold))
                        StickerGrid(stickers: pack.stickers) { sticker in
                            onSend(sticker)
                            dismiss()
                        }
                        StickerEgressDisclosure()
                    }
                    .padding(16)
                }
            }
        } else {
            ContentUnavailableView {
                Label(L10n.string("No Stickers"), systemImage: "face.dashed")
            } description: {
                Text(L10n.string("Add a sticker pack to send stickers."))
            } actions: {
                WNButton(title: "Browse Sticker Packs", size: .compact) { showsBrowser = true }
                    .fixedSize()
            }
        }
    }

    private var packTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(library.installed, id: \.coordinate) { pack in
                    let isSelected = pack.coordinate == currentPack?.coordinate
                    Button {
                        selectedPack = pack.coordinate
                    } label: {
                        Group {
                            if let cover = pack.cover ?? pack.stickers.first {
                                StickerImage(sticker: StickerKey(cover), loadsAutomatically: true)
                            } else {
                                Image(systemName: "face.dashed")
                            }
                        }
                        .frame(width: StickerMetrics.packTabSide, height: StickerMetrics.packTabSide)
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(isSelected ? Color(.tertiarySystemFill) : .clear)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(StickerPackPresentation.title(pack))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct StickerGrid: View {
    let stickers: [StickerFfi]
    var onSelect: ((StickerFfi) -> Void)?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: StickerMetrics.gridMinimum), spacing: 12)], spacing: 12) {
            ForEach(stickers, id: \.shortcode) { sticker in
                let image = StickerImage(sticker: StickerKey(sticker), loadsAutomatically: true)
                    .frame(height: StickerMetrics.gridMinimum)
                if let onSelect {
                    Button { onSelect(sticker) } label: { image }
                        .buttonStyle(.plain)
                        .accessibilityLabel(StickerLoadPolicy.accessibilityLabel(alt: sticker.alt, emoji: sticker.emoji))
                        .accessibilityHint(L10n.string("Sends this sticker"))
                } else {
                    image
                }
            }
        }
    }
}

private struct StickerEgressDisclosure: View {
    var body: some View {
        Text(L10n.string("Stickers load from servers each pack’s author chose. Those servers can see your IP address."))
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Browsing and installing

struct StickerPackBrowserView: View {
    let library: StickerLibrary

    @State private var search = ""
    @State private var link = ""
    @State private var discovered: [StickerPackFfi] = []
    @State private var isLoading = false
    @State private var syncError: String?
    @State private var isLookingUp = false
    @State private var lookedUp: StickerPackFfi?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                TextField(L10n.string("Sticker pack link"), text: $link)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .onSubmit(lookUp)
                Button(L10n.string("Open Link"), action: lookUp)
                    .disabled(StickerPackPresentation.lookupInput(link) == nil || isLookingUp)
            } header: {
                Text(L10n.string("Add by Link"))
            } footer: {
                Text(L10n.string("Paste a Sonar sticker pack link or an naddr."))
            }

            if !library.installed.isEmpty {
                Section(L10n.string("Installed")) {
                    ForEach(library.installed, id: \.coordinate) { pack in
                        NavigationLink {
                            StickerPackDetailView(library: library, pack: pack)
                        } label: {
                            StickerPackRow(pack: pack)
                        }
                    }
                    .onDelete(perform: uninstall)
                }
            }

            Section {
                switch StickerPackPresentation.discoveryState(
                    isLoading: isLoading, packCount: discovered.count, search: search, syncError: syncError) {
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity)
                case .packs:
                    ForEach(discovered, id: \.coordinate) { pack in
                        NavigationLink {
                            StickerPackDetailView(library: library, pack: pack)
                        } label: {
                            StickerPackRow(pack: pack)
                        }
                    }
                case .noneOnRelays:
                    Text(L10n.string("Your relays don’t have any sticker packs yet. Paste a pack link above to add one."))
                        .foregroundStyle(.secondary)
                case .noMatches:
                    Text(L10n.string("No sticker packs match your search."))
                        .foregroundStyle(.secondary)
                case .unreachable(let message):
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.string("Couldn’t check your relays for sticker packs."))
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
                Text(L10n.string("Sticker packs are public and aren’t reviewed by White Noise. Your installed packs are listed publicly on your relays."))
            }
        }
        .navigationTitle(L10n.string("Sticker Packs"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: L10n.string("Search sticker packs"))
        .task(id: search) { await reloadDiscovered(debounce: !search.isEmpty) }
        .refreshable { await reloadDiscovered(debounce: false, forceSync: true) }
        .navigationDestination(item: $lookedUp) { pack in
            StickerPackDetailView(library: library, pack: pack)
        }
        .alert(L10n.string("Sticker Packs"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(L10n.string("OK"), role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
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
                try await library.sync(force: forceSync)
                syncError = nil
            } catch is CancellationError {
                return
            } catch {
                syncError = UserFacingError.message(for: error)
            }
            let packs = try await library.discover(search: search)
            guard !Task.isCancelled else { return }
            discovered = packs
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = UserFacingError.message(for: error)
        }
    }

    private func lookUp() {
        guard let input = StickerPackPresentation.lookupInput(link), !isLookingUp else { return }
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
        let packs = offsets.map { library.installed[$0] }
        Task {
            for pack in packs {
                do {
                    try await library.uninstall(pack)
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

/// A pack as text only: its artwork loads once the pack is opened.
private struct StickerPackRow: View {
    let pack: StickerPackFfi

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(StickerPackPresentation.title(pack))
                .font(.body)
                .lineLimit(1)
            Text(StickerPackPresentation.summary(pack))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct StickerPackDetailView: View {
    let library: StickerLibrary
    let pack: StickerPackFfi

    @State private var isWorking = false
    @State private var errorMessage: String?

    private var isInstalled: Bool { library.isInstalled(pack.coordinate) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(StickerPackPresentation.summary(pack))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(L10n.formatted("By %@", IdentityPresentation.text(accountIdHex: pack.authorPubkeyHex)))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let description = StickerPackPresentation.description(pack) {
                    Text(description)
                        .font(.body)
                }
                StickerGrid(stickers: pack.stickers)
                StickerEgressDisclosure()
            }
            .padding(16)
        }
        .navigationTitle(StickerPackPresentation.title(pack))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isWorking {
                    ProgressView()
                } else {
                    Button(isInstalled ? L10n.string("Remove") : L10n.string("Add"), action: toggleInstall)
                }
            }
        }
        .alert(StickerPackPresentation.title(pack), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(L10n.string("OK"), role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func toggleInstall() {
        guard !isWorking else { return }
        let installing = !isInstalled
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                if installing {
                    try await library.install(pack)
                } else {
                    try await library.uninstall(pack)
                }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = UserFacingError.message(for: error)
            }
        }
    }
}
