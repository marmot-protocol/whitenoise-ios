import SwiftUI

extension EnvironmentValues {
    @Entry var isTranscriptMediaSheet = false
}

/// The transcript viewer opens on the tapped slot. Paging updates both the
/// navigation title and the source used by the current page's actions.
struct TranscriptMediaSheet<Page: View>: View {
    @Environment(\.transcriptHistoryControls) private var history
    @State private var actionRead: Task<Void, Never>?
    @State private var showsActionFailure = false
    let gallery: MessageMediaGallery
    @Binding var selection: String
    let isZoomed: Bool
    let showsChrome: Bool
    let controls: MediaViewerControlState
    let onClose: () -> Void
    let onSave: () -> Void
    let onShare: () -> Void
    let onForward: () -> Void
    let onGoToMessage: () -> Void
    @ViewBuilder let page: (MessageMediaAttachment) -> Page

    private var position: Binding<String?> {
        Binding(get: { selection }, set: { id in
            // While a draft id is being reconciled, layout can report a neighbouring page.
            if let id, gallery.transcriptCaptions?[selection] != nil, gallery.transcriptCaptions?[id] != nil { selection = id }
        })
    }

    var body: some View {
        NavigationStack {
            pager
                .background(Color(.systemBackground))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "chevron.backward", action: onClose)
                            .labelStyle(.iconOnly)
                    }
                    ToolbarItem(placement: .principal) {
                        if let caption = gallery.transcriptCaptions?[selection] {
                            VStack(spacing: 0) {
                                Text(caption.sender).font(.headline)
                                Text(caption.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            if let refresh = history?.refresh {
                                Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
                            }
                            if let load = history?.loadMore {
                                Button("Load more", systemImage: "photo.on.rectangle", action: load)
                                    .disabled(history?.isLoading == true)
                            }
                            Button("Save", systemImage: "square.and.arrow.down") { verified(onSave) }
                                .disabled(history == nil || !controls.canSave)
                            if controls.canGoToMessage {
                                Button("Go to Message", systemImage: "bubble.left", action: onGoToMessage)
                            }
                        } label: { Label("More", systemImage: "ellipsis") }
                    }
                }
                .toolbar(showsChrome ? .visible : .hidden, for: .navigationBar)
                .safeAreaInset(edge: .bottom) {
                    if showsChrome {
                        VStack(spacing: 4) {
                            if history?.pageFailed == true {
                                HStack {
                                        Text("Couldn't load shared media.")
                                        Button("Retry") { history?.loadMore?() }
                                    }
                                    .font(.caption)
                                } else if let checked = history?.checkedWithoutOverlap {
                                    Text("Attachments checked: \(checked)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                HStack {
                                MessageMediaGalleryButton(title: "Share", systemImage: "square.and.arrow.up", action: onShare)
                                    .disabled(!controls.canShare)
                                Spacer()
                                MessageMediaGalleryButton(title: "Forward", systemImage: "arrowshape.turn.up.right", action: { verified(onForward) })
                                    .disabled(history == nil || !controls.canForward)
                            }
                        }
                        .safeAreaPadding(.horizontal, 20)
                        .padding(.vertical, 8)
                    }
                }
        }
        .onChange(of: selection) { _, itemID in
            history?.didSelect(itemID)
            actionRead?.cancel()
            if itemID == gallery.items.first?.id { history?.loadMore?() }
        }
        .onDisappear { actionRead?.cancel() }
        .alert("Media unavailable", isPresented: $showsActionFailure) {
            Button("OK", role: .cancel) {}
        }
        .environment(\.isTranscriptMediaSheet, true)
        .presentationDetents([.large])
        .interactiveDismissDisabled(isZoomed)
    }

    private func verified(_ action: @escaping () -> Void) {
        guard let item = gallery.items.first(where: { $0.id == selection }) else { return }
        actionRead?.cancel()
        actionRead = Task {
            let allowed = await gallery.mayExport(item, verify: history?.verify)
            guard !Task.isCancelled, selection == item.id else { return }
            if allowed { action() }
            else { showsActionFailure = true }
        }
    }

    @ViewBuilder private var pager: some View {
        let scroll = ScrollView(.horizontal) {
            LazyHStack(spacing: 32) {
                ForEach(gallery.items) { item in
                    page(item)
                        .containerRelativeFrame(.horizontal)
                        .id(item.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollDisabled(isZoomed)
        .scrollPosition(id: position, anchor: .center)
        if #available(iOS 26, *) {
            scroll.scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne, anchor: .center))
                .scrollEdgeEffectHidden(true, for: .top)
        } else {
            scroll.scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
        }
    }
}
