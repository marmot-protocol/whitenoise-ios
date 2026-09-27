import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A cropped image chosen through the avatar photo menu.
nonisolated struct WNPhotoSourceSelection: Equatable {
    let data: Data
    let fileName: String?
    let typeIdentifier: String?
    let sourceURL: URL?
    var preparedDraft: GroupImageUploadDraft?
}

nonisolated enum WNPhotoSourceKind: Equatable {
    case photos
    case files
}

/// What a photo-menu action opens. Photos and Files are the only sources whose
/// bytes can end up on a public host, so only they go behind the disclosure;
/// screens whose image stays inside the encrypted group pass
/// `confirmsPublicUpload: false` and reach the picker directly.
nonisolated enum WNPhotoSourceRoute: Equatable {
    case open(WNPhotoSourceKind)
    case confirmPublicUpload(WNPhotoSourceKind)
    case web
    case remove

    static func route(
        for action: WNPhotoMenuAction,
        confirmsPublicUpload: Bool
    ) -> Self {
        switch action {
        case .chooseFromPhotos:
            confirmsPublicUpload ? .confirmPublicUpload(.photos) : .open(.photos)
        case .chooseFromFiles:
            confirmsPublicUpload ? .confirmPublicUpload(.files) : .open(.files)
        case .findImageOnWeb:
            .web
        case .removePhoto:
            .remove
        }
    }
}

/// Both avatar controls expose the same native photo-source actions.
struct WNAvatarPhotoMenu<Preview: View>: View {
    let hasPhoto: Bool
    @Binding var selection: WNPhotoMenuAction?
    @ViewBuilder var preview: () -> Preview

    var body: some View {
        VStack(spacing: 0) {
            Menu {
                WNPhotoMenuActions(hasPhoto: hasPhoto, selection: $selection)
            } label: {
                preview()
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .containerRelativeFrame(.horizontal, count: 3, span: 1, spacing: 0)
            .accessibilityLabel(hasPhoto ? "Change Photo" : "Add Photo")

            WNPhotoMenuButton(hasPhoto: hasPhoto, selection: $selection)
                .padding(.top)
        }
    }
}

extension View {
    /// Routes native menu selections through the shared pickers and crop editor.
    func wnPhotoSourceMenu(
        selection: Binding<WNPhotoMenuAction?>,
        confirmsPublicUpload: Bool,
        onError: @escaping (Error) -> Void,
        onRemove: @escaping () -> Void,
        onSelect: @escaping (WNPhotoSourceSelection) async throws -> Void
    ) -> some View {
        modifier(
            WNPhotoSourceMenuModifier(
                selection: selection,
                confirmsPublicUpload: confirmsPublicUpload,
                onError: onError,
                onRemove: onRemove,
                onSelect: onSelect
            )
        )
    }
}

private struct WNPhotoSourceMenuModifier: ViewModifier {
    @State private var sourceTask: Task<Void, Never>?
    @Binding var selection: WNPhotoMenuAction?
    let confirmsPublicUpload: Bool
    let onError: (Error) -> Void
    let onRemove: () -> Void
    let onSelect: (WNPhotoSourceSelection) async throws -> Void

    @State private var pendingSource: WNPhotoSourceKind?
    @State private var showDisclosure = false
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var showWebImagePicker = false
    @State private var cropSource: AvatarImageCropSource?
    @State private var fileFailure: PhotoSelectionFailure?
    @State private var failedFileURL: URL?

    func body(content: Content) -> some View {
        content
            .onDisappear { sourceTask?.cancel() }
            .onChange(of: selection) { _, action in
                guard let action else { return }
                selection = nil
                switch WNPhotoSourceRoute.route(
                    for: action,
                    confirmsPublicUpload: confirmsPublicUpload
                ) {
                case .open(let kind):
                    open(kind)
                case .confirmPublicUpload(let kind):
                    pendingSource = kind
                    showDisclosure = true
                case .web:
                    showWebImagePicker = true
                case .remove:
                    onRemove()
                }
            }
            .alert("Your avatar is public", isPresented: $showDisclosure) {
                Button("Continue") {
                    if let pendingSource {
                        open(pendingSource)
                    }
                    pendingSource = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingSource = nil
                }
            } message: {
                Text("The photo is uploaded to a public service, and removing it from your profile may not delete the uploaded copy.")
            }
            .sheet(isPresented: $showPhotoPicker) {
                WNPhotoLibraryCropFlow(
                    onCrop: select,
                    onClose: { showPhotoPicker = false }
                )
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.image],
                allowsMultipleSelection: false
            ) { result in
                prepareImportedFile(result)
            }
            .sheet(isPresented: $showWebImagePicker) {
                OnboardingAvatarWebImagePicker(onCrop: select)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .alert("Couldn’t add photo", isPresented: Binding(
                get: { fileFailure != nil }, set: { if !$0 { fileFailure = nil } }
            ), presenting: fileFailure) { failure in
                if failure.canRetry, let failedFileURL {
                    Button("Retry") { startImport(failedFileURL) }
                    Button("Close", role: .cancel) {}
                } else {
                    Button("Choose Another Photo") { showFileImporter = true }
                }
            } message: { failure in Text(failure.message) }
            .fullScreenCover(item: $cropSource) { source in
                NavigationStack {
                    AvatarImageCropEditor(source: source, onCrop: select)
                }
            }
    }

    private func select(_ source: AvatarImageCropSource, _ croppedData: Data) async throws {
        let draft = try await ProfileImageDraftProcessor.prepare(
            data: croppedData, fileName: source.fileName, typeIdentifier: "public.jpeg", sourceURL: source.sourceURL
        )
        try Task.checkCancellation()
        try await onSelect(
            WNPhotoSourceSelection(
                data: croppedData,
                fileName: source.fileName,
                typeIdentifier: "public.jpeg",
                sourceURL: source.sourceURL,
                preparedDraft: draft
            )
        )
    }

    private func open(_ kind: WNPhotoSourceKind) {
        switch kind {
        case .photos:
            showPhotoPicker = true
        case .files:
            showFileImporter = true
        }
    }

    private func prepareImportedFile(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            startImport(url)
        case .failure(let error):
            if (error as? CocoaError)?.code != .userCancelled {
                fileFailure = PhotoSelectionFailure.classify(error)
            }
        }
    }

    private func startImport(_ url: URL) {
        sourceTask?.cancel()
        sourceTask = Task { await loadImportedFile(url) }
    }

    private func loadImportedFile(_ url: URL) async {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                try AvatarImageCropper.boundedFileData(from: url)
            }.value
            let source = try await AvatarImageCropSource(
                data: data,
                fileName: url.lastPathComponent,
                typeIdentifier: nil,
                sourceURL: url
            ).prepared()
            try Task.checkCancellation()
            cropSource = source
        } catch {
            guard !Task.isCancelled else { return }
            failedFileURL = url
            fileFailure = PhotoSelectionFailure.classify(error)
        }
    }
}

struct WNPhotoLibraryCropFlow: View {
    let onCrop: (AvatarImageCropSource, Data) async throws -> Void
    let onClose: () -> Void

    @State private var item: PhotosPickerItem?
    @State private var isLoading = false
    @State private var failure: PhotoSelectionFailure?
    @State private var source: AvatarImageCropSource?

    var body: some View {
        NavigationStack {
            PhotosPicker(selection: $item, matching: .images) {
                EmptyView()
            }
            .photosPickerStyle(.inline)
            .photosPickerDisabledCapabilities(.selectionActions)
            .photosPickerAccessoryVisibility(.hidden, edges: .all)
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onClose)
                }
            }
            .overlay {
                if isLoading { ProgressView("Loading…").allowsHitTesting(false) }
            }
            .navigationDestination(item: $source) { source in
                AvatarImageCropEditor(source: source, onClose: onClose, onChooseAnother: { self.source = nil; item = nil }, onCrop: onCrop)
            }
        }
        .alert("Couldn’t add photo", isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } }
        ), presenting: failure) { _ in
            Button("Choose Another Photo") { item = nil }
        } message: { failure in Text(failure.message) }
        .task(id: item) {
            await load(item)
        }
    }

    private func load(_ item: PhotosPickerItem?) async {
        guard let item else { isLoading = false; return }
        source = nil
        isLoading = true
        defer { if !Task.isCancelled, self.item == item { isLoading = false } }
        do {
            guard let file = try await item.loadTransferable(type: WNPhotoLibraryFile.self) else {
                throw MediaDraftProcessor.Failure.unsupportedImage
            }
            try Task.checkCancellation()
            let prepared = try await AvatarImageCropSource(
                data: file.data,
                fileName: file.fileName,
                typeIdentifier: item.supportedContentTypes.first?.identifier,
                sourceURL: nil
            ).prepared()
            guard self.item == item else { return }
            source = prepared
        } catch {
            guard !Task.isCancelled else { return }
            failure = PhotoSelectionFailure.classify(error)
        }
    }
}

private nonisolated struct WNPhotoLibraryFile: Transferable {
    let data: Data
    let fileName: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            Self(
                data: try AvatarImageCropper.boundedFileData(from: received.file),
                fileName: received.file.lastPathComponent
            )
        }
    }
}
