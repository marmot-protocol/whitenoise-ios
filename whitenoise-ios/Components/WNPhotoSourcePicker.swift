import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A cropped image chosen through the avatar photo menu.
nonisolated struct WNPhotoSourceSelection: Equatable {
    let data: Data
    let fileName: String?
    let typeIdentifier: String?
    let sourceURL: URL?
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

/// The editable avatar shared by Sign Up, Profile and New Group: the circle and
/// the Add/Change Photo trigger open the same menu, so the whole avatar is the
/// tap target. Both carry the trigger's own label, because they do one thing.
struct WNAvatarPhotoMenu<Preview: View>: View {
    let hasPhoto: Bool
    @Binding var isPresented: Bool
    @ViewBuilder var preview: () -> Preview

    var body: some View {
        VStack(spacing: 0) {
            Button {
                isPresented = true
            } label: {
                preview()
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .containerRelativeFrame(.horizontal, count: 3, span: 1, spacing: 0)
            .accessibilityLabel(hasPhoto ? "Change Photo" : "Add Photo")

            WNPhotoMenuButton(hasPhoto: hasPhoto, isPresented: $isPresented)
                .padding(.top)
        }
    }
}

extension View {
    /// Draws the avatar photo menu over this container and wires its four
    /// sources — Photos, Files, web search and removal — through the shared
    /// square crop editor. Apply outside any `disabled` the form carries, so the
    /// menu's own rows stay tappable.
    func wnPhotoSourceMenu(
        isPresented: Binding<Bool>,
        hasPhoto: Bool,
        confirmsPublicUpload: Bool,
        onError: @escaping (Error) -> Void,
        onRemove: @escaping () -> Void,
        onSelect: @escaping (WNPhotoSourceSelection) -> Void
    ) -> some View {
        modifier(
            WNPhotoSourceMenuModifier(
                isPresented: isPresented,
                hasPhoto: hasPhoto,
                confirmsPublicUpload: confirmsPublicUpload,
                onError: onError,
                onRemove: onRemove,
                onSelect: onSelect
            )
        )
    }
}

private struct WNPhotoSourceMenuModifier: ViewModifier {
    @Binding var isPresented: Bool
    let hasPhoto: Bool
    let confirmsPublicUpload: Bool
    let onError: (Error) -> Void
    let onRemove: () -> Void
    let onSelect: (WNPhotoSourceSelection) -> Void

    @State private var pendingSource: WNPhotoSourceKind?
    @State private var showDisclosure = false
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var showWebImagePicker = false
    @State private var cropSource: AvatarImageCropSource?

    func body(content: Content) -> some View {
        content
            .wnPhotoMenu(isPresented: $isPresented, hasPhoto: hasPhoto) { action in
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
                PhotoLibraryPickerView(
                    selectionLimit: 1,
                    filter: .images,
                    onSelection: { selections in
                        guard let selection = selections.first else { return }
                        cropSource = AvatarImageCropSource(
                            data: selection.data,
                            fileName: selection.fileName,
                            typeIdentifier: selection.typeIdentifier,
                            sourceURL: nil
                        )
                    },
                    onError: onError,
                    onDismiss: { showPhotoPicker = false }
                )
                .ignoresSafeArea()
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.image],
                allowsMultipleSelection: false
            ) { result in
                prepareImportedFile(result)
            }
            .sheet(isPresented: $showWebImagePicker) {
                OnboardingAvatarWebImagePicker { url in
                    prepareWebImage(url)
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .fullScreenCover(item: $cropSource) { source in
                AvatarImageCropEditor(source: source) { source, croppedData in
                    onSelect(
                        WNPhotoSourceSelection(
                            data: croppedData,
                            fileName: source.fileName,
                            typeIdentifier: "public.jpeg",
                            sourceURL: source.sourceURL
                        )
                    )
                }
            }
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
            Task { await loadImportedFile(url) }
        case .failure(let error):
            onError(error)
        }
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
            cropSource = AvatarImageCropSource(
                data: data,
                fileName: url.lastPathComponent,
                typeIdentifier: nil,
                sourceURL: url
            )
        } catch {
            onError(error)
        }
    }

    private func prepareWebImage(_ url: URL) {
        Task {
            do {
                let data = try await RemoteImageFetch.imageData(for: url)
                cropSource = AvatarImageCropSource(
                    data: data,
                    fileName: url.lastPathComponent,
                    typeIdentifier: nil,
                    sourceURL: url
                )
            } catch {
                onError(error)
            }
        }
    }
}
