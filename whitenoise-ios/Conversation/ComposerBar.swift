import AVFoundation
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

nonisolated enum ComposerSideIconTone: Equatable {
    case primary
    case disabled

    var color: Color {
        switch self {
        case .primary:
            Color.primary
        case .disabled:
            Color.secondary.opacity(0.45)
        }
    }
}

nonisolated enum ComposerAttachmentButtonTapBehavior: Equatable {
    case showOptions
    case showUnavailableTooltip
}

nonisolated struct ComposerAttachmentButtonAppearance: Equatable {
    let iconTone: ComposerSideIconTone
    let chromeInteractive: Bool
    let controlOpacity: Double
    let tapBehavior: ComposerAttachmentButtonTapBehavior

    static func mediaAvailability(_ mediaEnabled: Bool) -> ComposerAttachmentButtonAppearance {
        if mediaEnabled {
            return ComposerAttachmentButtonAppearance(
                iconTone: .primary,
                chromeInteractive: true,
                controlOpacity: 1,
                tapBehavior: .showOptions
            )
        }
        return ComposerAttachmentButtonAppearance(
            iconTone: .disabled,
            chromeInteractive: false,
            controlOpacity: 0.72,
            tapBehavior: .showUnavailableTooltip
        )
    }
}

private enum ComposerAttachmentPopover: String, Identifiable {
    case options
    case unavailable

    var id: String { rawValue }
}

nonisolated enum ComposerAudioDraftPreviewPresentation {
    static func playIconName(isPlaying: Bool, didFail: Bool) -> String {
        if isPlaying { return "pause.fill" }
        if didFail { return "arrow.clockwise" }
        return "play.fill"
    }

    static func durationLabel(_ duration: Double?) -> String {
        guard let duration else { return "" }
        let total = max(0, Int(duration.rounded(.down)))
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}

/// Telegram-style composer: attachment + pill input (emoji + send inside) + mic slot.
struct ComposerBar: View {
    @Binding var draft: String
    let isSending: Bool
    let hasAttachments: Bool
    let audioDraft: MediaDraftAttachment?
    let mediaEnabled: Bool
    let disabledMessage: String?
    let voiceRecordingActive: Bool
    let focusRequest: Int
    let mentionCandidates: [ComposerMentionCandidate]
    let onTakePhoto: () -> Void
    let onPhotoLibrary: () -> Void
    let onAttachFile: () -> Void
    let onRemoveAudioDraft: (MediaDraftAttachment.ID) -> Void
    let onVoicePressBegan: () -> Void
    let onVoiceDragChanged: (CGSize) -> Void
    let onVoicePressEnded: () -> Void
    let onMentionSelect: (ComposerMentionCandidate) -> Void
    let onSend: () -> Void
    @FocusState private var focused: Bool
    @State private var isKeyboardVisible = false
    @State private var attachmentPopover: ComposerAttachmentPopover?
    @State private var showEmojiPicker = false

    private var controlSize: CGFloat { BottomInputChromeLayout.controlSize }
    private var inlineSendSize: CGFloat { BottomInputChromeLayout.inlineSendSize }
    private var inputEnabled: Bool { disabledMessage == nil }

    var body: some View {
        VStack(spacing: 6) {
            if !mentionCandidates.isEmpty {
                ComposerMentionPicker(candidates: mentionCandidates, onSelect: onMentionSelect)
            }

            if let disabledMessage {
                inactiveComposerMessage(disabledMessage)
            }

            HStack(alignment: .bottom, spacing: BottomInputChromeLayout.rowSpacing) {
                bottomInputGlassContainer {
                    attachmentButton
                }
                bottomInputGlassContainer {
                    HStack(alignment: .bottom, spacing: BottomInputChromeLayout.rowSpacing) {
                        inputCapsule
                        trailingActionSlot
                    }
                }
            }
            .animation(.easeInOut(duration: 0.22), value: showsMic)
            .animation(.easeInOut(duration: 0.22), value: showsSend)
            .disabled(!inputEnabled)
            .opacity(inputEnabled ? 1 : 0.68)
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
        .onChange(of: inputEnabled) { _, enabled in
            guard !enabled else { return }
            focused = false
            attachmentPopover = nil
            showEmojiPicker = false
        }
    }

    private func inactiveComposerMessage(_ message: String) -> some View {
        Label {
            Text(message)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.circle")
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.bottom, 2)
    }

    private var attachmentButton: some View {
        let attachmentEnabled = inputEnabled && mediaEnabled
        let appearance = ComposerAttachmentButtonAppearance.mediaAvailability(attachmentEnabled)

        return Button {
            handleAttachmentTap(appearance.tapBehavior)
        } label: {
            sideCircleIcon(
                "paperclip",
                weight: .medium,
                size: BottomInputChromeLayout.sideControlIconSize,
                tone: appearance.iconTone,
                interactive: appearance.chromeInteractive
            )
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .opacity(appearance.controlOpacity)
        .accessibilityLabel("Add attachment")
        .accessibilityHint(attachmentAccessibilityHint)
        .popover(
            item: $attachmentPopover,
            attachmentAnchor: .rect(.rect(CGRect(
                x: controlSize / 2,
                y: -BottomInputChromeLayout.attachmentMenuAnchorLift,
                width: 0,
                height: 0
            ))),
            arrowEdge: .bottom
        ) { popover in
            switch popover {
            case .options:
                ComposerAttachmentMenu(
                    onPhotoLibrary: {
                        attachmentPopover = nil
                        onPhotoLibrary()
                    },
                    onTakePhoto: {
                        attachmentPopover = nil
                        onTakePhoto()
                    },
                    onAttachFile: {
                        attachmentPopover = nil
                        onAttachFile()
                    }
                )
            case .unavailable:
                ComposerAttachmentUnavailableTooltip()
            }
        }
    }

    private var inputCapsule: some View {
        HStack(alignment: audioDraft == nil ? .bottom : .center, spacing: 0) {
            if let audioDraft {
                ComposerAudioDraftInput(
                    attachment: audioDraft,
                    onRemove: { onRemoveAudioDraft(audioDraft.id) }
                )
                .transition(.opacity)
            } else {
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
        .padding(.trailing, 4)
        .accessibilityLabel("Emoji and stickers")
    }

    private var sendButton: some View {
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
    private var trailingActionSlot: some View {
        if showsSend {
            sendButton
                .frame(width: controlSize, height: controlSize)
                .transition(.scale(scale: 0.88).combined(with: .opacity))
        } else if showsMic {
            sideCircleIcon(
                "mic.fill",
                weight: .semibold,
                size: BottomInputChromeLayout.sideControlIconSize,
                tone: inputEnabled ? .primary : .disabled
            )
            .scaleEffect(voiceRecordingActive ? 1.08 : 1)
            .contentShape(Circle())
            .gesture(voiceGesture)
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
        tone: ComposerSideIconTone = .primary,
        interactive: Bool = true
    ) -> some View {
        Image(systemName: name)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(tone.color)
            .frame(width: controlSize, height: controlSize)
            .compatibleInputCircleChrome(interactive: interactive)
    }

    private var hasSendableContent: Bool {
        hasAttachments || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSend: Bool {
        inputEnabled && !isSending && hasSendableContent
    }

    private var showsSend: Bool {
        hasSendableContent
    }

    private var showsMic: Bool {
        (!hasSendableContent && !isSending) || voiceRecordingActive
    }

    private var voiceGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                guard inputEnabled else { return }
                if !voiceRecordingActive {
                    onVoicePressBegan()
                }
                onVoiceDragChanged(value.translation)
            }
            .onEnded { _ in
                guard inputEnabled else { return }
                onVoicePressEnded()
            }
    }

    private func triggerSend() {
        guard canSend else { return }
        Haptics.tap()
        onSend()
    }

    private var attachmentAccessibilityHint: String {
        if let disabledMessage { return disabledMessage }
        return mediaEnabled ? "" : L10n.string("Media is not available in this group")
    }

    private func handleAttachmentTap(_ behavior: ComposerAttachmentButtonTapBehavior) {
        switch behavior {
        case .showOptions:
            attachmentPopover = .options
        case .showUnavailableTooltip:
            attachmentPopover = .unavailable
        }
    }

    private func focusComposer() {
        guard inputEnabled else { return }
        guard audioDraft == nil else { return }
        Task { @MainActor in
            await Task.yield()
            focused = true
        }
    }
}

private struct ComposerAudioDraftInput: View {
    let attachment: MediaDraftAttachment
    let onRemove: () -> Void

    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var progress: CGFloat = 0
    @State private var isLoading = false
    @State private var didFail = false
    @State private var progressTask: Task<Void, Never>?
    @State private var audioSessionLease: VoiceAudioSession.Lease?

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.10), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove attachment")

            Button(action: togglePlayback) {
                Group {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: ComposerAudioDraftPreviewPresentation.playIconName(
                            isPlaying: isPlaying,
                            didFail: didFail
                        ))
                        .font(.system(size: 13, weight: .bold))
                    }
                }
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.accentColor, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Pause audio message" : "Play audio message")

            AudioWaveformView(
                samples: attachment.waveformSamples,
                progress: progress,
                barColor: Color.accentColor.opacity(0.88),
                playedColor: Color.accentColor
            )
            .frame(maxWidth: .infinity)
            .frame(height: 30)

            Text(ComposerAudioDraftPreviewPresentation.durationLabel(attachment.durationSeconds))
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity)
        .frame(minHeight: BottomInputChromeLayout.controlSize)
        .onChange(of: attachment.id) { _, _ in
            stopPlayback()
            progress = 0
            didFail = false
        }
        .onDisappear {
            stopPlayback()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Voice message")
    }

    private func togglePlayback() {
        if isPlaying {
            player?.pause()
            isPlaying = false
            releaseAudioSession()
            return
        }
        if player == nil || didFail {
            loadAndPlay()
        } else {
            playLoadedAudio()
        }
    }

    private func loadAndPlay() {
        isLoading = true
        didFail = false
        do {
            let next = try AVAudioPlayer(data: attachment.data)
            next.prepareToPlay()
            player = next
            isLoading = false
            playLoadedAudio()
        } catch {
            isLoading = false
            didFail = true
            isPlaying = false
            releaseAudioSession()
        }
    }

    private func playLoadedAudio() {
        guard let player else { return }
        do {
            releaseAudioSession()
            audioSessionLease = try VoiceAudioSession.configureForPlayback()
        } catch {
            didFail = true
            isPlaying = false
            return
        }
        if player.currentTime >= player.duration {
            player.currentTime = 0
            progress = 0
        }
        guard player.play() else {
            didFail = true
            isPlaying = false
            releaseAudioSession()
            return
        }
        didFail = false
        isPlaying = true
        startProgressLoop()
    }

    private func startProgressLoop() {
        progressTask?.cancel()
        progressTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard let player else { return }
                let duration = max(0.01, player.duration)
                progress = min(1, max(0, CGFloat(player.currentTime / duration)))
                if !player.isPlaying {
                    isPlaying = false
                    releaseAudioSession()
                    if progress >= 0.995 {
                        progress = 0
                        player.currentTime = 0
                    }
                    return
                }
            }
        }
    }

    private func stopPlayback() {
        progressTask?.cancel()
        progressTask = nil
        player?.stop()
        player = nil
        isPlaying = false
        releaseAudioSession()
    }

    private func releaseAudioSession() {
        VoiceAudioSession.deactivate(audioSessionLease)
        audioSessionLease = nil
    }
}

private struct ComposerAttachmentUnavailableTooltip: View {
    var body: some View {
        Text(L10n.string("Media is not available in this group"))
            .font(.footnote.weight(.medium))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 220)
            .fixedSize(horizontal: false, vertical: true)
            .presentationCompactAdaptation(.popover)
    }
}

private struct ComposerAttachmentMenu: View {
    let onPhotoLibrary: () -> Void
    let onTakePhoto: () -> Void
    let onAttachFile: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            actionRow("Take Photo", systemImage: "camera", action: onTakePhoto)
            Divider()
            actionRow("Photo Library", systemImage: "photo.on.rectangle", action: onPhotoLibrary)
            Divider()
            actionRow("Attach File", systemImage: "doc.badge.plus", action: onAttachFile)
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
