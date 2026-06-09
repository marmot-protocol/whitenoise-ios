import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

struct MediaDraftStrip: View {
    let attachments: [MediaDraftAttachment]
    let onRemove: (MediaDraftAttachment.ID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        thumbnail(for: attachment)
                            .frame(width: 68, height: 68)
                            .clipShape(.rect(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                            }

                        Button {
                            onRemove(attachment.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 19, weight: .semibold))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Color(.systemBackground), Color.primary.opacity(0.82))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove photo")
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
    private func thumbnail(for attachment: MediaDraftAttachment) -> some View {
        if let image = UIImage(data: attachment.data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Color(.secondarySystemBackground)
                Image(systemName: "photo")
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
}

private enum PhotoLibraryPickerError: LocalizedError {
    case noReadableImage

    var errorDescription: String? {
        switch self {
        case .noReadableImage:
            return L10n.string("That image could not be opened.")
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
        configuration.filter = .images
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
        private let resultQueue = DispatchQueue(label: "dev.ipf.darkmatter.photo-library-picker")

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
            var selections: [PhotoLibrarySelection] = []
            var firstError: Error?

            for result in results {
                let provider = result.itemProvider
                guard let typeIdentifier = Self.imageTypeIdentifier(from: provider) else { continue }
                let fileName = Self.fileName(
                    suggestedName: provider.suggestedName,
                    typeIdentifier: typeIdentifier
                )

                group.enter()
                provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                    self.resultQueue.async {
                        if let data, !data.isEmpty {
                            selections.append(PhotoLibrarySelection(data: data, fileName: fileName))
                        } else if let error, firstError == nil {
                            firstError = error
                        }
                        group.leave()
                    }
                }
            }

            group.notify(queue: .main) {
                if selections.isEmpty {
                    self.onError(firstError ?? PhotoLibraryPickerError.noReadableImage)
                } else {
                    self.onSelection(selections)
                }
            }
        }

        private static func imageTypeIdentifier(from provider: NSItemProvider) -> String? {
            provider.registeredTypeIdentifiers.first { identifier in
                UTType(identifier)?.conforms(to: .image) == true
            } ?? (provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) ? UTType.image.identifier : nil)
        }

        private static func fileName(suggestedName: String?, typeIdentifier: String) -> String? {
            let trimmed = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let trimmed, !trimmed.isEmpty else {
                return UTType(typeIdentifier)?.preferredFilenameExtension.map { "photo.\($0)" }
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
