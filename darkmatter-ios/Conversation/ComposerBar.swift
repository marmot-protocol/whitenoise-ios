import SwiftUI

nonisolated enum ComposerInputChrome {
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

/// Telegram-style composer: attachment + pill input (emoji + send inside) + mic slot.
struct ComposerBar: View {
    @Binding var draft: String
    let isSending: Bool
    let hasAttachments: Bool
    let mediaEnabled: Bool
    let focusRequest: Int
    let mentionCandidates: [ComposerMentionCandidate]
    let onTakePhoto: () -> Void
    let onPhotoLibrary: () -> Void
    let onMentionSelect: (ComposerMentionCandidate) -> Void
    let onSend: () -> Void
    @FocusState private var focused: Bool
    @State private var isKeyboardVisible = false
    @State private var showAttachmentOptions = false
    @State private var showEmojiPicker = false

    private var controlSize: CGFloat { BottomInputChromeLayout.controlSize }
    private var inlineSendSize: CGFloat { BottomInputChromeLayout.inlineSendSize }

    var body: some View {
        VStack(spacing: 6) {
            if !mentionCandidates.isEmpty {
                ComposerMentionPicker(candidates: mentionCandidates, onSelect: onMentionSelect)
            }

            HStack(alignment: .bottom, spacing: BottomInputChromeLayout.rowSpacing) {
                bottomInputGlassContainer {
                    attachmentButton
                }
                bottomInputGlassContainer {
                    HStack(alignment: .bottom, spacing: BottomInputChromeLayout.rowSpacing) {
                        inputCapsule
                        micSlot
                    }
                }
            }
            .animation(.easeInOut(duration: 0.22), value: showsMic)
            .animation(.easeInOut(duration: 0.22), value: showsSend)
        }
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $showEmojiPicker) {
            EmojiPickerSheet(title: nil) { emoji in
                draft.append(emoji)
                focusComposer()
            }
            .appAppearance()
        }
        .keyboardAdaptiveHorizontalPadding(isKeyboardVisible: $isKeyboardVisible)
        .padding(.top, BottomInputChromeLayout.topInset)
        .padding(.bottom, BottomInputChromeLayout.bottomInset)
    }

    private var attachmentButton: some View {
        Button {
            showAttachmentOptions = true
        } label: {
            sideCircleIcon(
                "paperclip",
                weight: .medium,
                size: BottomInputChromeLayout.sideControlIconSize
            )
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .disabled(!mediaEnabled)
        .opacity(mediaEnabled ? 1 : 0.45)
        .accessibilityLabel("Add attachment")
        .popover(
            isPresented: $showAttachmentOptions,
            attachmentAnchor: .rect(.rect(CGRect(
                x: controlSize / 2,
                y: -BottomInputChromeLayout.attachmentMenuAnchorLift,
                width: 0,
                height: 0
            ))),
            arrowEdge: .bottom
        ) {
            ComposerAttachmentMenu(
                onPhotoLibrary: {
                    showAttachmentOptions = false
                    onPhotoLibrary()
                },
                onTakePhoto: {
                    showAttachmentOptions = false
                    onTakePhoto()
                }
            )
        }
    }

    private var inputCapsule: some View {
        HStack(alignment: .bottom, spacing: 0) {
            TextField("Message", text: $draft, axis: .vertical)
                .focused($focused)
                .lineLimit(1...5)
                .font(.system(size: BottomInputChromeLayout.fieldFontSize))
                .padding(.leading, BottomInputChromeLayout.fieldLeadingPadding)
                .padding(.vertical, BottomInputChromeLayout.fieldVerticalPadding)
                .padding(.trailing, BottomInputChromeLayout.fieldTrailingPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { focusComposer() })
                .submitLabel(.send)
                .onSubmit(triggerSend)
                .onChange(of: focusRequest) { _, _ in focusComposer() }
                .onAppear {
                    if focusRequest > 0 {
                        focusComposer()
                    }
                }

            emojiButton

            if showsSend {
                inlineSendButton
                    .padding(.trailing, 4)
                    .padding(.bottom, 2)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(minHeight: controlSize)
        .frame(maxWidth: .infinity)
        .compatibleInputCapsuleChrome(interactive: false)
    }

    private var emojiButton: some View {
        Button {
            Haptics.tap()
            showEmojiPicker = true
        } label: {
            Image(systemName: "face.smiling")
                .font(.system(size: BottomInputChromeLayout.inlineEmojiIconSize))
                .foregroundStyle(.secondary)
                .frame(width: BottomInputChromeLayout.inlineAccessoryWidth, height: controlSize)
        }
        .buttonStyle(.plain)
        .padding(.trailing, showsSend ? 0 : 4)
        .accessibilityLabel("Emoji and stickers")
    }

    private var inlineSendButton: some View {
        Button(action: triggerSend) {
            Group {
                if isSending {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: BottomInputChromeLayout.inlineSendIconSize, weight: .semibold))
                        .foregroundStyle(.white)
                        .offset(x: -1, y: 1)
                }
            }
            .frame(width: inlineSendSize, height: inlineSendSize)
            .background(Circle().fill(Color.accentColor))
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .opacity(canSend ? 1 : 0.55)
        .accessibilityLabel("Send")
    }

    @ViewBuilder
    private var micSlot: some View {
        if showsMic {
            Button {
                // Voice messages — wired in a follow-up.
            } label: {
                sideCircleIcon("mic.fill", weight: .semibold, size: BottomInputChromeLayout.sideControlIconSize)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Voice message")
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .trailing).combined(with: .opacity)
            ))
        }
    }

    private func sideCircleIcon(
        _ name: String,
        weight: Font.Weight,
        size: CGFloat,
        interactive: Bool = true
    ) -> some View {
        Image(systemName: name)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(.primary)
            .frame(width: controlSize, height: controlSize)
            .compatibleInputCircleChrome(interactive: interactive)
    }

    private var hasSendableContent: Bool {
        hasAttachments || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSend: Bool {
        !isSending && hasSendableContent
    }

    private var showsSend: Bool {
        hasSendableContent
    }

    private var showsMic: Bool {
        !hasSendableContent && !isSending
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

private struct ComposerAttachmentMenu: View {
    let onPhotoLibrary: () -> Void
    let onTakePhoto: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            actionRow("Photo Library", systemImage: "photo.on.rectangle", action: onPhotoLibrary)
            Divider()
            actionRow("Take Photo", systemImage: "camera", action: onTakePhoto)
        }
        .frame(width: 220)
        .presentationCompactAdaptation(.popover)
    }

    private func actionRow(
        _ title: LocalizedStringKey,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .frame(width: 22)
                Text(title)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}

private struct ComposerMentionPicker: View {
    let candidates: [ComposerMentionCandidate]
    let onSelect: (ComposerMentionCandidate) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(candidates) { candidate in
                    Button {
                        Haptics.tap()
                        onSelect(candidate)
                    } label: {
                        HStack(spacing: 10) {
                            AvatarBubble(
                                seed: candidate.memberIdHex,
                                title: candidate.displayName,
                                pictureURL: candidate.avatarPictureURL
                            )
                            .frame(width: 32, height: 32)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(candidate.displayName)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text(IdentityFormatter.short(candidate.npub))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxHeight: 220)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemBackground).opacity(0.82))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        }
        .padding(.horizontal, BottomInputChromeLayout.horizontalInset)
    }
}
