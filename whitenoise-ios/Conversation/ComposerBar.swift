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

    static let controlSize: CGFloat = 44
    static let rowSpacing: CGFloat = 8
    static let inputSpacing: CGFloat = 4
    static let horizontalInset: CGFloat = 16
    static let verticalInset: CGFloat = 6
    static let sendButtonSize: CGFloat = 32
    static let cornerRadius: CGFloat = 22
}

nonisolated struct ComposerSendButtonAppearance: Equatable {
    enum Tone: Equatable {
        case black
        case white

        var color: Color {
            switch self {
            case .black: .black
            case .white: .white
            }
        }
    }

    let fill: Tone
    let symbol: Tone

    static func colorScheme(_ colorScheme: ColorScheme) -> ComposerSendButtonAppearance {
        colorScheme == .dark
            ? ComposerSendButtonAppearance(fill: .white, symbol: .black)
            : ComposerSendButtonAppearance(fill: .black, symbol: .white)
    }
}

nonisolated struct ComposerReplyPreview: Equatable {
    let title: String
    let body: String
}

nonisolated enum ComposerVoiceChromePresentation {
    static func showsCancel(isActive: Bool) -> Bool {
        isActive
    }

    static func showsStop(isActive: Bool, isLocked: Bool) -> Bool {
        isActive && isLocked
    }

    static func textEntryOpacity(isActive: Bool) -> Double {
        isActive ? 0 : 1
    }
}

nonisolated enum ComposerSideIconTone: Equatable {
    case primary
    case disabled
    case destructive

    var color: Color {
        switch self {
        case .primary:
            Color.primary
        case .disabled:
            Color.secondary.opacity(0.45)
        case .destructive:
            Color.red
        }
    }
}

nonisolated enum ComposerAttachmentButtonTapBehavior: Equatable {
    case showOptions
    case showUnavailableTooltip
}

nonisolated enum ComposerAvailabilityPresentation {
    static func showsInput(disabledMessage: String?) -> Bool {
        disabledMessage == nil
    }
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

nonisolated enum AudioDurationLabel {
    private static let maximumDisplaySeconds = Int.max / 2

    static func label(for duration: Double, locale: Locale = AppLanguage.currentLocale) -> String {
        label(forTotalSeconds: totalSeconds(clamping: duration), locale: locale)
    }

    static func optionalLabel(for duration: Double?, locale: Locale = AppLanguage.currentLocale) -> String? {
        guard let duration, duration.isFinite else { return nil }
        return label(for: duration, locale: locale)
    }

    private static func totalSeconds(clamping duration: Double) -> Int {
        guard duration.isFinite, duration > 0 else { return 0 }
        guard duration < Double(maximumDisplaySeconds) else { return maximumDisplaySeconds }
        return Int(duration.rounded(.down))
    }

    private static func label(forTotalSeconds totalSeconds: Int, locale: Locale) -> String {
        let minutes = String(format: "%lld", locale: locale, Int64(totalSeconds / 60))
        let seconds = String(format: "%02lld", locale: locale, Int64(totalSeconds % 60))
        return L10n.formatted("%@:%@", arguments: [minutes, seconds], locale: locale)
    }
}

nonisolated enum ComposerAudioDraftPreviewPresentation {
    static func playIconName(isPlaying: Bool, didFail: Bool) -> String {
        if isPlaying { return "pause.fill" }
        if didFail { return "arrow.clockwise" }
        return "play.fill"
    }

    static func durationLabel(_ duration: Double?) -> String {
        guard let duration else { return "" }
        return AudioDurationLabel.label(for: duration)
    }
}

/// Conversation composer with attachment, emoji, text, send, and voice controls.
struct ComposerBar: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var draft: String
    let isSending: Bool
    let hasAttachments: Bool
    let audioDraft: MediaDraftAttachment?
    let preparedAttachments: [MediaDraftAttachment]
    let replyPreview: ComposerReplyPreview?
    let mediaEnabled: Bool
    let disabledMessage: String?
    let voiceRecordingActive: Bool
    let voiceRecordingLocked: Bool
    let voiceRecordingSamples: [CGFloat]
    let voiceRecordingDurationSeconds: Double
    let focusRequest: Int
    let dismissRequest: Int
    /// Reports text-input focus upward so the conversation can restore it
    /// after a cancelled interactive pop, and only then.
    var onInputFocusChange: (Bool) -> Void = { _ in }
    let mentionCandidates: [ComposerMentionCandidate]
    var submissionEnabled = true
    var submissionAccessibilityLabel = L10n.string("Send")
    var voiceMessagesEnabled = true
    var cameraAvailable = true
    var gifsAvailable = true
    let onTakePhoto: () -> Void
    let onPhotoLibrary: () -> Void
    let onAttachFile: () -> Void
    let onShareLocation: () -> Void
    let onShareContact: () -> Void
    let onSearchGIFs: () -> Void
    let onPasteImage: (UIImage) -> Void
    let onRemoveAudioDraft: (MediaDraftAttachment.ID) -> Void
    let onRemovePreparedAttachment: (MediaDraftAttachment.ID) -> Void
    let onPreviewPreparedMedia: (MediaDraftAttachment.ID) -> Void
    let onCancelReply: () -> Void
    let onCancelVoiceRecording: () -> Void
    let onStopVoiceRecording: () -> Void
    let onVoicePressBegan: () -> Void
    let onVoiceDragChanged: (CGSize) -> Void
    let onVoicePressEnded: () -> Void
    let onMentionSelect: (ComposerMentionCandidate) -> Void
    let onSend: () -> Void
    @State private var isTextInputFocused = false
    @State private var showAttachmentUnavailableTooltip = false
    @State private var showExpandedEditor = false
    @State private var localFocusRequest = 0

    @ScaledMetric(relativeTo: .body)
    private var controlSize = ComposerInputChrome.controlSize
    @ScaledMetric(relativeTo: .body)
    private var inlineSendSize = ComposerInputChrome.sendButtonSize
    @ScaledMetric(relativeTo: .body)
    private var fieldFontSize = BottomInputChromeLayout.fieldFontSize
    @ScaledMetric(relativeTo: .body)
    private var sideControlIconSize = BottomInputChromeLayout.sideControlIconSize
    @ScaledMetric(relativeTo: .body)
    private var inlineSendIconSize = BottomInputChromeLayout.inlineSendIconSize

    private var inputEnabled: Bool { disabledMessage == nil }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                if !mentionCandidates.isEmpty {
                    ComposerMentionPicker(candidates: mentionCandidates, onSelect: onMentionSelect)
                }

                if ComposerAvailabilityPresentation.showsInput(disabledMessage: disabledMessage) {
                    bottomInputGlassContainer(spacing: ComposerInputChrome.rowSpacing) {
                        HStack(alignment: .bottom, spacing: ComposerInputChrome.rowSpacing) {
                            if ComposerVoiceChromePresentation.showsCancel(isActive: voiceRecordingActive) {
                                recordingCancelButton
                            } else {
                                attachmentButton
                            }
                            VStack(spacing: 0) {
                                preparedContent

                                HStack(alignment: .bottom, spacing: ComposerInputChrome.inputSpacing) {
                                    inputCapsule
                                    trailingActionSlot
                                        .animation(.easeInOut(duration: 0.22), value: showsMic)
                                        .animation(.easeInOut(duration: 0.22), value: showsSend)
                                }
                            }
                            .frame(minHeight: controlSize)
                            .frame(maxWidth: .infinity)
                            .compatibleInputRoundedChrome(
                                cornerRadius: controlSize / 2,
                                interactive: false,
                                usesRegularGlass: true
                            )
                        }
                    }
                } else if let disabledMessage {
                    inactiveComposerMessage(disabledMessage)
                }
            }
            .padding(.horizontal, ComposerInputChrome.horizontalInset)
            .padding(.vertical, ComposerInputChrome.verticalInset)
        }
        .fixedSize(horizontal: false, vertical: true)
        .fullScreenCover(isPresented: $showExpandedEditor) {
            ExpandedComposerEditor(
                draft: $draft,
                canSend: canSend,
                onDone: { showExpandedEditor = false },
                onSend: {
                    triggerSend()
                    showExpandedEditor = false
                }
            )
            .appAppearance()
        }
        .onChange(of: isTextInputFocused) { _, focused in
            onInputFocusChange(focused)
        }
        .onChange(of: focusRequest) { _, _ in
            showSystemKeyboard()
        }
        .onChange(of: dismissRequest) { _, _ in
            isTextInputFocused = false
        }
        .onChange(of: inputEnabled) { _, enabled in
            guard !enabled else { return }
            showAttachmentUnavailableTooltip = false
            isTextInputFocused = false
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

    @ViewBuilder
    private var attachmentButton: some View {
        let appearance = ComposerAttachmentButtonAppearance
            .mediaAvailability(inputEnabled && mediaEnabled)

        switch appearance.tapBehavior {
        case .showOptions:
            WNDropdown(
                items: ComposerAttachmentOption.dropdownItems(
                    cameraAvailable: cameraAvailable,
                    gifsAvailable: gifsAvailable
                ),
                onSelect: selectAttachmentOption
            ) {
                attachmentIcon(appearance)
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .opacity(appearance.controlOpacity)
            // A staged audio draft owns the composer until it is sent or removed.
            .disabled(audioDraft != nil)
            .accessibilityLabel(L10n.string("Add attachment"))
            .accessibilityHint(attachmentAccessibilityHint)
        case .showUnavailableTooltip:
            Button {
                showAttachmentUnavailableTooltip = true
            } label: {
                attachmentIcon(appearance)
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .opacity(appearance.controlOpacity)
            .accessibilityLabel(L10n.string("Add attachment"))
            .accessibilityHint(attachmentAccessibilityHint)
            .popover(
                isPresented: $showAttachmentUnavailableTooltip,
                attachmentAnchor: .rect(.rect(CGRect(
                    x: controlSize / 2,
                    y: -BottomInputChromeLayout.attachmentMenuAnchorLift,
                    width: 0,
                    height: 0
                ))),
                arrowEdge: .bottom
            ) {
                ComposerAttachmentUnavailableTooltip()
            }
        }
    }

    private func attachmentIcon(
        _ appearance: ComposerAttachmentButtonAppearance
    ) -> some View {
        sideCircleIcon(
            "plus",
            weight: .medium,
            size: sideControlIconSize,
            tone: appearance.iconTone,
            interactive: appearance.chromeInteractive
        )
    }

    private var inputCapsule: some View {
        HStack(alignment: audioDraft == nil ? .bottom : .center, spacing: 0) {
            if let audioDraft, !voiceRecordingActive {
                ComposerAudioDraftInput(
                    attachment: audioDraft,
                    onRemove: { onRemoveAudioDraft(audioDraft.id) }
                )
                .transition(.opacity)
            } else {
                ZStack {
                    composerTextEntry
                        .opacity(ComposerVoiceChromePresentation.textEntryOpacity(isActive: voiceRecordingActive))
                        .allowsHitTesting(!voiceRecordingActive)
                        .accessibilityHidden(voiceRecordingActive)

                    if voiceRecordingActive {
                        ComposerVoiceRecordingInput(
                            samples: voiceRecordingSamples,
                            durationSeconds: voiceRecordingDurationSeconds
                        )
                    }
                }
            }
        }
        .frame(minHeight: controlSize)
        .frame(maxWidth: .infinity)
    }

    private var composerTextEntry: some View {
        HStack(alignment: .bottom, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if draft.isEmpty {
                    Text(L10n.string("Message"))
                        .font(.system(size: fieldFontSize))
                        .foregroundStyle(.secondary)
                        .padding(.top, BottomInputChromeLayout.fieldVerticalPadding)
                }

                ComposerTextInput(
                    text: $draft,
                    isFocused: $isTextInputFocused,
                    fontSize: fieldFontSize,
                    focusRequest: focusRequest &* 1_000 &+ localFocusRequest,
                    onPasteImage: onPasteImage
                )
            }
            .padding(.leading, BottomInputChromeLayout.fieldLeadingPadding)
            .frame(maxWidth: .infinity, alignment: .leading)

            if ComposerExpandedEditorPresentation.shouldShowExpandButton(for: draft) {
                Button {
                    Haptics.tap()
                    showExpandedEditor = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.string("Expand editor"))
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var preparedContent: some View {
        if !preparedAttachments.isEmpty {
            MediaDraftStrip(
                attachments: preparedAttachments,
                onRemove: onRemovePreparedAttachment,
                onPreviewVisual: onPreviewPreparedMedia
            )
        }

        if let replyPreview {
            ComposerReplyPreviewView(
                preview: replyPreview,
                onCancel: onCancelReply
            )
        }
    }

    private var recordingCancelButton: some View {
        Button(action: onCancelVoiceRecording) {
            sideCircleIcon(
                "xmark",
                weight: .semibold,
                size: sideControlIconSize,
                tone: .destructive
            )
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .accessibilityLabel("Cancel recording")
    }

    private var sendButton: some View {
        let appearance = ComposerSendButtonAppearance.colorScheme(colorScheme)

        return Button(action: triggerSend) {
            Group {
                if isSending {
                    ProgressView()
                        .controlSize(.small)
                        .tint(appearance.symbol.color)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: inlineSendIconSize, weight: .semibold))
                        .foregroundStyle(appearance.symbol.color)
                }
            }
            .frame(width: inlineSendSize, height: inlineSendSize)
            .background(Circle().fill(appearance.fill.color))
            .frame(width: controlSize, height: controlSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!canSend)
        .opacity(canSend ? 1 : 0.55)
        .accessibilityLabel(submissionAccessibilityLabel)
    }

    @ViewBuilder
    private var trailingActionSlot: some View {
        if ComposerVoiceChromePresentation.showsStop(
            isActive: voiceRecordingActive,
            isLocked: voiceRecordingLocked
        ) {
            Button(action: onStopVoiceRecording) {
                Image(systemName: "stop.fill")
                    .font(.system(size: inlineSendIconSize, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: inlineSendSize, height: inlineSendSize)
                    .background(Color.red, in: Circle())
                    .frame(width: controlSize, height: controlSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Finish recording")
        } else if showsSend {
            sendButton
                .transition(.scale(scale: 0.88).combined(with: .opacity))
        } else if showsMic {
            Image(systemName: "waveform")
                .font(.system(size: sideControlIconSize, weight: .semibold))
                .foregroundStyle(
                    inputEnabled
                        ? ComposerSideIconTone.primary.color
                        : ComposerSideIconTone.disabled.color
                )
                .frame(width: controlSize, height: controlSize)
                .scaleEffect(voiceRecordingActive ? 1.08 : 1)
                .contentShape(Rectangle())
                .gesture(voiceGesture)
                .accessibilityLabel("Voice message")
                .transition(.identity)
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
            .compatibleInputCircleChrome(interactive: interactive, usesRegularGlass: true)
    }

    private var hasSendableContent: Bool {
        hasAttachments || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSend: Bool {
        inputEnabled && !isSending && hasSendableContent && submissionEnabled
    }

    private var showsSend: Bool {
        hasSendableContent
    }

    private var showsMic: Bool {
        voiceMessagesEnabled && ((!hasSendableContent && !isSending) || voiceRecordingActive)
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

    private func selectAttachmentOption(_ option: ComposerAttachmentOption) {
        isTextInputFocused = false
        Task { @MainActor in
            // Let the menu finish dismissing before a system-owned picker
            // starts presenting over the same window.
            await Task.yield()
            performAttachmentOption(option)
        }
    }

    private func performAttachmentOption(_ option: ComposerAttachmentOption) {
        switch option {
        case .camera:
            onTakePhoto()
        case .photosAndVideos:
            onPhotoLibrary()
        case .files:
            onAttachFile()
        case .gifs:
            onSearchGIFs()
        case .location:
            onShareLocation()
        case .contact:
            onShareContact()
        }
    }

    private func showSystemKeyboard() {
        guard inputEnabled else { return }
        guard audioDraft == nil else { return }
        isTextInputFocused = true
        localFocusRequest &+= 1
    }
}

private struct ComposerReplyPreviewView: View {
    let preview: ComposerReplyPreview
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            VStack(alignment: .leading, spacing: 2) {
                Text(preview.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if !preview.body.isEmpty {
                    Text(preview.body)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 32)
        }
        .padding(.leading, 20)
        .padding(.trailing, 4)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemFill), in: .rect(cornerRadius: 12))
        .overlay(alignment: .leading) {
            Capsule()
                .fill(.secondary)
                .frame(width: 3)
                .padding(.leading, 10)
                .padding(.vertical, 8)
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel reply")
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

private struct ComposerVoiceRecordingInput: View {
    let samples: [CGFloat]
    let durationSeconds: Double

    var body: some View {
        HStack(spacing: 8) {
            AudioWaveformView(
                samples: samples,
                progress: 0,
                barColor: Color.red.opacity(0.78),
                playedColor: .red,
                mode: .liveRecording
            )
            .frame(maxWidth: .infinity)
            .frame(height: 30)

            Text(AudioDurationLabel.label(for: durationSeconds))
                .font(.body.monospacedDigit())
                .foregroundStyle(.red)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.leading, 14)
        .frame(maxWidth: .infinity, minHeight: ComposerInputChrome.controlSize)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "Recording, \(AudioDurationLabel.label(for: durationSeconds))"))
    }
}

private struct ComposerAudioDraftInput: View {
    @Environment(\.colorScheme) private var colorScheme
    let attachment: MediaDraftAttachment
    let onRemove: () -> Void

    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var progress: CGFloat = 0
    @State private var isLoading = false
    @State private var didFail = false
    @State private var progressTask: Task<Void, Never>?
    @State private var audioSessionLease: VoiceAudioSession.Lease?

    @ScaledMetric(relativeTo: .footnote)
    private var draftControlSize: CGFloat = 28

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: draftControlSize, height: draftControlSize)
                    .background(Color.primary.opacity(0.10), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove attachment")

            Button(action: togglePlayback) {
                Group {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.primary)
                    } else {
                        Image(systemName: ComposerAudioDraftPreviewPresentation.playIconName(
                            isPlaying: isPlaying,
                            didFail: didFail
                        ))
                        .font(.footnote.weight(.bold))
                    }
                }
                .foregroundStyle(.primary)
                .frame(width: draftControlSize, height: draftControlSize)
                .background(.quaternary, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Pause audio message" : "Play audio message")

            AudioWaveformView(
                samples: attachment.waveformSamples,
                progress: progress,
                barColor: colorScheme == .dark ? .white : .black,
                playedColor: colorScheme == .dark ? .white : .black
            )
            .frame(maxWidth: .infinity)
            .frame(height: 30)

            Text(ComposerAudioDraftPreviewPresentation.durationLabel(attachment.durationSeconds))
                .font(.body.monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
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

nonisolated enum ComposerExpandedEditorPresentation {
    static let minimumExpandCharacterCount = 180

    static func shouldShowExpandButton(for text: String) -> Bool {
        text.count >= minimumExpandCharacterCount
            || text.contains(where: \.isNewline)
    }
}

private struct ExpandedComposerEditor: View {
    @Binding var draft: String
    let canSend: Bool
    let onDone: () -> Void
    let onSend: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            TextEditor(text: $draft)
                .font(.body)
                .padding()
                .focused($focused)
                .navigationTitle(L10n.string("Message"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.string("Done"), action: onDone)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(action: onSend) {
                            Image(systemName: "paperplane.fill")
                        }
                        .disabled(!canSend)
                        .accessibilityLabel(L10n.string("Send"))
                    }
                }
        }
        .onAppear { focused = true }
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
