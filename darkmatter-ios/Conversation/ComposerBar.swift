import SwiftUI

enum ComposerInputChrome {
    enum FillBase: Equatable {
        case systemBackground
        case black

        var color: Color {
            switch self {
            case .systemBackground:
                Color(.systemBackground)
            case .black:
                Color.black
            }
        }
    }

    struct OverlayFill: Equatable {
        let base: FillBase
        let opacity: Double

        var color: Color {
            base.color.opacity(opacity)
        }
    }

    static func overlayFill(for colorScheme: ColorScheme) -> OverlayFill {
        switch colorScheme {
        case .light:
            OverlayFill(base: .systemBackground, opacity: 0.88)
        case .dark:
            OverlayFill(base: .black, opacity: 0.26)
        @unknown default:
            OverlayFill(base: .systemBackground, opacity: 0.88)
        }
    }
}

/// Glass-styled composer at the bottom of the conversation screen. Multi-line
/// growing text field + send button. Disabled while a send is in-flight.
struct ComposerBar: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var draft: String
    let isSending: Bool
    let hasAttachments: Bool
    let mediaEnabled: Bool
    let focusRequest: Int
    let onTakePhoto: () -> Void
    let onPhotoLibrary: () -> Void
    let onSend: () -> Void
    @FocusState private var focused: Bool

    private let controlHeight: CGFloat = 40

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Menu {
                Button(action: onTakePhoto) {
                    Label("Take Photo", systemImage: "camera")
                }

                Button(action: onPhotoLibrary) {
                    Label("Photo Library", systemImage: "photo.on.rectangle")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(mediaEnabled ? Color.primary : Color.secondary)
                    .frame(width: controlHeight, height: controlHeight)
                    .background {
                        Circle().fill(Color(.tertiarySystemFill))
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add photo")

            TextField("Message", text: $draft, axis: .vertical)
                .focused($focused)
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(minHeight: controlHeight)
                .foregroundStyle(.primary)
                .background {
                    ZStack {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(.ultraThinMaterial)
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(ComposerInputChrome.overlayFill(for: colorScheme).color)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                }
                .submitLabel(.send)
                .onSubmit(triggerSend)
                .onChange(of: focusRequest) { _, _ in focusComposer() }
                .onAppear {
                    if focusRequest > 0 {
                        focusComposer()
                    }
                }

            Button(action: triggerSend) {
                Group {
                    if isSending {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color(.systemBackground))
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Color(.systemBackground))
                    }
                }
                .frame(width: controlHeight, height: controlHeight)
                .background(Circle().fill(canSend ? Color.primary : Color.secondary.opacity(0.3)))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .animation(.easeInOut(duration: 0.15), value: canSend)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var canSend: Bool {
        !isSending && (hasAttachments || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func triggerSend() {
        guard canSend else { return }
        Haptics.tap()
        onSend()
    }

    private func focusComposer() {
        Task { @MainActor in
            await Task.yield()
            focused = true
        }
    }
}
