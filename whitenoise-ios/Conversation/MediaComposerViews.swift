import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

nonisolated enum ComposerMediaDraftPresentation {
    static func inlineAudioDraft(in attachments: [MediaDraftAttachment]) -> MediaDraftAttachment? {
        let audioDrafts = attachments.filter { $0.kind == .audio }
        return audioDrafts.count == 1 ? audioDrafts[0] : nil
    }

    static func stripAttachments(from attachments: [MediaDraftAttachment]) -> [MediaDraftAttachment] {
        guard let inlineAudio = inlineAudioDraft(in: attachments) else {
            return attachments
        }
        return attachments.filter { $0.id != inlineAudio.id }
    }
}

nonisolated enum VideoPreviewOverlayPresentation {
    static let compactDiameter: CGFloat = 44
    static let regularDiameter: CGFloat = 64
    static let maximumDiameter: CGFloat = 76

    static func diameter(for size: CGSize) -> CGFloat {
        let shortestSide = min(size.width, size.height)
        guard shortestSide.isFinite, shortestSide >= 96 else {
            return compactDiameter
        }
        return min(maximumDiameter, max(regularDiameter, shortestSide * 0.24))
            .rounded(.toNearestOrAwayFromZero)
    }

    static func iconFontSize(for diameter: CGFloat) -> CGFloat {
        max(19, diameter * 0.42).rounded(.toNearestOrAwayFromZero)
    }
}

struct VideoPreviewPlayOverlay: View {
    var systemName = "play.fill"
    let diameter: CGFloat

    var body: some View {
        Image(systemName: systemName)
            .font(.system(
                size: VideoPreviewOverlayPresentation.iconFontSize(for: diameter),
                weight: .bold
            ))
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
            .background(Color.black.opacity(0.5), in: Circle())
            .shadow(color: Color.black.opacity(0.28), radius: 8, y: 2)
    }
}

struct MediaDraftStrip: View {
    let attachments: [MediaDraftAttachment]
    let onRemove: (MediaDraftAttachment.ID) -> Void

    private let visualPreviewSideLength: CGFloat = 68

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        preview(for: attachment)

                        Button {
                            onRemove(attachment.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 19, weight: .semibold))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Color(.systemBackground), Color.primary.opacity(0.82))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove attachment")
                        .offset(x: 7, y: -7)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
        .background(Color(.systemBackground).opacity(0.86))
    }

    @ViewBuilder
    private func preview(for attachment: MediaDraftAttachment) -> some View {
        switch attachment.kind {
        case .image, .video:
            ZStack {
                thumbnail(for: attachment)
                if attachment.kind == .video {
                    VideoPreviewPlayOverlay(
                        diameter: VideoPreviewOverlayPresentation.diameter(
                            for: CGSize(width: visualPreviewSideLength, height: visualPreviewSideLength)
                        )
                    )
                }
            }
            .frame(width: visualPreviewSideLength, height: visualPreviewSideLength)
            .clipShape(.rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            }
        case .audio:
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                AudioWaveformView(
                    samples: attachment.waveformSamples,
                    progress: 0,
                    barColor: Color.accentColor.opacity(0.88),
                    playedColor: Color.accentColor
                )
                .frame(width: 82, height: 34)
            }
            .padding(.horizontal, 10)
            .frame(width: 142, height: 68)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            }
        case .document, .unsupported:
            VStack(spacing: 5) {
                Image(systemName: attachment.kind.systemImageName)
                    .font(.system(size: 18, weight: .semibold))
                Text(attachment.fileName)
                    .font(.caption2)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary)
            .padding(8)
            .frame(width: 112, height: 68)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private func thumbnail(for attachment: MediaDraftAttachment) -> some View {
        if let thumbnail = attachment.thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Color(.secondarySystemBackground)
                Image(systemName: attachment.kind.systemImageName)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct CameraCaptureView: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onImage: onImage, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = .camera
        picker.mediaTypes = ["public.image"]
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onImage: (UIImage) -> Void
        let onCancel: () -> Void

        init(onImage: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onImage = onImage
            self.onCancel = onCancel
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onImage(image)
            } else {
                onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}

struct PhotoLibrarySelection: Hashable {
    let data: Data
    let fileName: String?
    let typeIdentifier: String?

    init(data: Data, fileName: String?, typeIdentifier: String? = nil) {
        self.data = data
        self.fileName = fileName
        self.typeIdentifier = typeIdentifier
    }

    static func compactPreservingPickerOrder(_ selectionsByPickerIndex: [PhotoLibrarySelection?]) -> [PhotoLibrarySelection] {
        selectionsByPickerIndex.compactMap { $0 }
    }
}

private enum PhotoLibraryPickerError: LocalizedError {
    case noReadableMedia

    var errorDescription: String? {
        switch self {
        case .noReadableMedia:
            return L10n.string("That attachment could not be opened.")
        }
    }
}

struct PhotoLibraryPickerView: UIViewControllerRepresentable {
    let selectionLimit: Int
    let onSelection: ([PhotoLibrarySelection]) -> Void
    let onError: (Error) -> Void
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelection: onSelection, onError: onError, onDismiss: onDismiss)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .any(of: [.images, .videos])
        configuration.selectionLimit = max(1, selectionLimit)
        configuration.preferredAssetRepresentationMode = .current

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onSelection: ([PhotoLibrarySelection]) -> Void
        private let onError: (Error) -> Void
        private let onDismiss: () -> Void
        private let resultQueue = DispatchQueue(label: "dev.ipf.whitenoise.ios.photo-library-picker")

        init(
            onSelection: @escaping ([PhotoLibrarySelection]) -> Void,
            onError: @escaping (Error) -> Void,
            onDismiss: @escaping () -> Void
        ) {
            self.onSelection = onSelection
            self.onError = onError
            self.onDismiss = onDismiss
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            onDismiss()
            guard !results.isEmpty else { return }

            let group = DispatchGroup()
            var selectionsByPickerIndex = [PhotoLibrarySelection?](repeating: nil, count: results.count)
            var firstError: Error?

            for (index, result) in results.enumerated() {
                let provider = result.itemProvider
                guard let typeIdentifier = Self.mediaTypeIdentifier(from: provider) else { continue }
                let fileName = Self.fileName(
                    suggestedName: provider.suggestedName,
                    typeIdentifier: typeIdentifier
                )

                group.enter()
                provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                    self.resultQueue.async {
                        if let data, !data.isEmpty {
                            selectionsByPickerIndex[index] = PhotoLibrarySelection(
                                data: data,
                                fileName: fileName,
                                typeIdentifier: typeIdentifier
                            )
                        } else if let error, firstError == nil {
                            firstError = error
                        }
                        group.leave()
                    }
                }
            }

            group.notify(queue: .main) {
                let selections = PhotoLibrarySelection.compactPreservingPickerOrder(selectionsByPickerIndex)
                if selections.isEmpty {
                    self.onError(firstError ?? PhotoLibraryPickerError.noReadableMedia)
                } else {
                    self.onSelection(selections)
                }
            }
        }

        private static func mediaTypeIdentifier(from provider: NSItemProvider) -> String? {
            provider.registeredTypeIdentifiers.first { identifier in
                guard let type = UTType(identifier) else { return false }
                return type.conforms(to: .image) || type.conforms(to: .movie)
            } ?? {
                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    return UTType.image.identifier
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                    return UTType.movie.identifier
                }
                return nil
            }()
        }

        private static func fileName(suggestedName: String?, typeIdentifier: String) -> String? {
            let trimmed = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let trimmed, !trimmed.isEmpty else {
                return UTType(typeIdentifier)?.preferredFilenameExtension.map { "attachment.\($0)" }
            }
            guard !trimmed.contains("."),
                  let fileExtension = UTType(typeIdentifier)?.preferredFilenameExtension,
                  !fileExtension.isEmpty else {
                return trimmed
            }
            return "\(trimmed).\(fileExtension)"
        }
    }
}
