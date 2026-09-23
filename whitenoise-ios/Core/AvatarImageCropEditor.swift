import ImageIO
import SwiftUI
import UIKit

/// Raw image data awaiting the same square crop treatment regardless of
/// whether it came from Photos, Files, or a web-search result.
struct AvatarImageCropSource: Identifiable, Sendable {
    let id = UUID()
    let data: Data
    let fileName: String?
    let typeIdentifier: String?
    let sourceURL: URL?
}

nonisolated enum AvatarImageCropper {
    static let maximumZoom: CGFloat = 6
    static let maximumEncodedBytes = 25 * 1024 * 1024
    static let maximumSourcePixelCount = 80_000_000
    static let maximumEditorPixelSize = 2_048
    static let outputPixelSize = 1_024
    static let maximumCropSide: CGFloat = 300
    static let minimumCropSide: CGFloat = 140

    static func encodedByteCountIsAllowed(_ count: Int) -> Bool {
        count > 0 && count <= maximumEncodedBytes
    }

    static func sourceDimensionsAreAllowed(width: Int, height: Int) -> Bool {
        width > 0
            && height > 0
            && width <= maximumSourcePixelCount / height
    }

    static func boundedFileData(
        from url: URL,
        maximumBytes: Int = maximumEncodedBytes
    ) throws -> Data {
        guard maximumBytes > 0 else {
            throw MediaDraftProcessor.Failure.attachmentTooLarge(0)
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile != false,
              values.fileSize.map({ $0 > 0 && $0 <= maximumBytes }) != false
        else {
            throw MediaDraftProcessor.Failure.attachmentTooLarge(values.fileSize ?? 0)
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        if let fileSize = values.fileSize {
            data.reserveCapacity(min(fileSize, maximumBytes))
        }
        let chunkSize = 64 * 1024
        while data.count <= maximumBytes {
            let remaining = maximumBytes - data.count
            guard let chunk = try handle.read(upToCount: min(chunkSize, remaining + 1)),
                  !chunk.isEmpty
            else { break }
            data.append(chunk)
            guard data.count <= maximumBytes else {
                throw MediaDraftProcessor.Failure.attachmentTooLarge(data.count)
            }
        }
        guard !data.isEmpty else {
            throw MediaDraftProcessor.Failure.attachmentTooLarge(data.count)
        }
        return data
    }

    static func normalizedImage(from data: Data) -> UIImage? {
        guard encodedByteCountIsAllowed(data.count),
              let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              sourceDimensionsAreAllowed(width: width, height: height)
        else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumEditorPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: image, scale: 1, orientation: .up)
    }

    static func clampedOffset(
        _ offset: CGSize,
        imageSize: CGSize,
        cropSide: CGFloat,
        zoom: CGFloat
    ) -> CGSize {
        let baseScale = max(cropSide / imageSize.width, cropSide / imageSize.height)
        let displayedSize = CGSize(
            width: imageSize.width * baseScale * zoom,
            height: imageSize.height * baseScale * zoom
        )
        let maximumX = max(0, (displayedSize.width - cropSide) / 2)
        let maximumY = max(0, (displayedSize.height - cropSide) / 2)
        return CGSize(
            width: min(max(offset.width, -maximumX), maximumX),
            height: min(max(offset.height, -maximumY), maximumY)
        )
    }

    static func fittedCropSide(_ available: CGSize) -> CGFloat {
        let side = min(available.width, available.height)
        guard side.isFinite, side > 0 else { return minimumCropSide }
        return min(max(side, minimumCropSide), maximumCropSide)
    }

    static func rescaledOffset(
        _ offset: CGSize,
        imageSize: CGSize,
        previousCropSide: CGFloat,
        cropSide: CGFloat,
        zoom: CGFloat
    ) -> CGSize {
        guard previousCropSide > 0, cropSide > 0 else { return .zero }
        let ratio = cropSide / previousCropSide
        return clampedOffset(
            CGSize(width: offset.width * ratio, height: offset.height * ratio),
            imageSize: imageSize,
            cropSide: cropSide,
            zoom: zoom
        )
    }

    static func croppedJPEG(
        image: UIImage,
        cropSide: CGFloat,
        zoom: CGFloat,
        offset: CGSize,
        outputPixelSide: Int = outputPixelSize
    ) -> Data? {
        guard outputPixelSide > 0, let cgImage = image.cgImage else { return nil }
        let imageSize = image.size
        let baseScale = max(cropSide / imageSize.width, cropSide / imageSize.height)
        let displayScale = baseScale * zoom
        let cropLength = cropSide / displayScale
        let origin = CGPoint(
            x: (imageSize.width - cropLength) / 2 - offset.width / displayScale,
            y: (imageSize.height - cropLength) / 2 - offset.height / displayScale
        )
        let rect = CGRect(origin: origin, size: CGSize(width: cropLength, height: cropLength))
            .integral
            .intersection(CGRect(origin: .zero, size: imageSize))
        guard rect.width > 0, rect.height > 0,
              let cropped = cgImage.cropping(to: rect)
        else { return nil }
        let outputSize = CGSize(width: outputPixelSide, height: outputPixelSide)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let output = UIGraphicsImageRenderer(size: outputSize, format: format).image { context in
            UIColor.systemBackground.setFill()
            context.fill(CGRect(origin: .zero, size: outputSize))
            UIImage(cgImage: cropped).draw(in: CGRect(origin: .zero, size: outputSize))
        }
        return output.jpegData(compressionQuality: 0.92)
    }
}

struct AvatarImageCropEditor: View {
    @Environment(\.dismiss) private var dismiss

    let source: AvatarImageCropSource?
    var onClose: (() -> Void)?
    let onCrop: (AvatarImageCropSource, Data) -> Void

    @State private var image: UIImage?
    @State private var isDecoding = true
    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    @State private var cropSide: CGFloat = AvatarImageCropper.maximumCropSide

    var body: some View {
        VStack(spacing: 24) {
            Group {
                if let image {
                    cropCanvas(image)
                } else if isDecoding {
                    ProgressView()
                        .controlSize(.large)
                } else {
                    ContentUnavailableView("Image", systemImage: "photo")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(maxHeight: AvatarImageCropper.maximumCropSide)
            .onGeometryChange(for: CGFloat.self) { proxy in
                AvatarImageCropper.fittedCropSide(proxy.size)
            } action: { side in
                resizeCrop(to: side)
            }

            Text("Pinch to zoom, then drag to position the image.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Crop image")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    close()
                } label: {
                    Image(systemName: "chevron.backward")
                        .imageScale(.large)
                }
                .accessibilityLabel(L10n.string("Back"))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            WNButton(title: "Done") {
                guard let source,
                      let image,
                      let data = AvatarImageCropper.croppedJPEG(
                        image: image,
                        cropSide: cropSide,
                        zoom: zoom,
                        offset: offset
                      )
                else { return }
                onCrop(source, data)
                close()
            }
            .disabled(image == nil)
            .safeAreaPadding(.horizontal)
            .padding(.vertical)
            .safeAreaPadding(.bottom)
        }
        .background {
            Color(.systemBackground)
                .ignoresSafeArea()
        }
        .navigationBarBackButtonHidden()
        .interactiveDismissDisabled()
        .task(id: source?.id) {
            guard let data = source?.data else { return }
            let prepared = await Task.detached(priority: .userInitiated) {
                AvatarImageCropper.normalizedImage(from: data)
            }.value
            guard !Task.isCancelled else { return }
            image = prepared
            isDecoding = false
        }
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    private func cropCanvas(_ image: UIImage) -> some View {
        let imageSize = image.size
        return ZStack {
            Color.black
            Image(uiImage: image)
                .resizable()
                .frame(
                    width: imageSize.width * baseScale(for: imageSize) * zoom,
                    height: imageSize.height * baseScale(for: imageSize) * zoom
                )
                .offset(offset)
        }
        .frame(width: cropSide, height: cropSide)
        .clipShape(.circle)
        .overlay {
            Circle()
                .strokeBorder(.white.opacity(0.55), lineWidth: 1)
        }
        .gesture(dragGesture(imageSize: imageSize).simultaneously(with: magnificationGesture(imageSize: imageSize)))
        .accessibilityLabel("Crop image")
    }

    private func resizeCrop(to side: CGFloat) {
        guard side > 0, side != cropSide else { return }
        let previous = cropSide
        cropSide = side
        guard let imageSize = image?.size else { return }
        offset = AvatarImageCropper.rescaledOffset(
            offset,
            imageSize: imageSize,
            previousCropSide: previous,
            cropSide: side,
            zoom: zoom
        )
        committedOffset = offset
    }

    private func baseScale(for imageSize: CGSize) -> CGFloat {
        max(cropSide / imageSize.width, cropSide / imageSize.height)
    }

    private func dragGesture(imageSize: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                offset = AvatarImageCropper.clampedOffset(
                    CGSize(
                        width: committedOffset.width + value.translation.width,
                        height: committedOffset.height + value.translation.height
                    ),
                    imageSize: imageSize,
                    cropSide: cropSide,
                    zoom: zoom
                )
            }
            .onEnded { _ in
                committedOffset = offset
            }
    }

    private func magnificationGesture(imageSize: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                zoom = min(max(committedZoom * value, 1), AvatarImageCropper.maximumZoom)
                offset = AvatarImageCropper.clampedOffset(
                    offset,
                    imageSize: imageSize,
                    cropSide: cropSide,
                    zoom: zoom
                )
            }
            .onEnded { _ in
                committedZoom = zoom
                committedOffset = offset
            }
    }
}
