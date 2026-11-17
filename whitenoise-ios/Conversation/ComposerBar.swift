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

    /// The send button never replaces the mic mid-hold: the mic carries the
    /// hold's gesture, so its release must still reach the recorder.
    static func showsSend(hasSendableContent: Bool, isActive: Bool) -> Bool {
        hasSendableContent && !isActive
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

    static func sendBlockedNotice(sendBlockedMessage: String?, hasSendableContent: Bool) -> String? {
        hasSendableContent ? sendBlockedMessage : nil
    }

    /// The over-limit count shows only above a visible text field, since the
    /// text has to be shortened there.
    static func textOverageNotice(
        overage: Int?,
        disabledMessage: String?,
        hasAudioDraft: Bool,
        voiceRecordingActive: Bool
    ) -> Int? {
        guard showsInput(disabledMessage: disabledMessage), !hasAudioDraft, !voiceRecordingActive else { return nil }
        return overage
    }

    static func awaitsLiveConversationState(
        usesLiveWindow: Bool,
        hasWindowSnapshot: Bool,
        hasLiveEpoch: Bool,
        hasWindowSubscription: Bool,
        isLocallyReset: Bool,
        isActiveParticipant: Bool,
        hasLoadingGraceExpired: Bool = false
    ) -> Bool {
        // Local-only snapshots already preserve known inactive membership.
        guard usesLiveWindow, !isLocallyReset, isActiveParticipant, !hasLoadingGraceExpired else { return false }
        // Cached rows can arrive before MDK has resolved live send capabilities.
        return !hasWindowSnapshot || !hasLiveEpoch || !hasWindowSubscription
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

/// What the composer needs to offer hold-to-dictate.
struct ComposerDictationBinding {
    let state: ComposerDictationController.State
    let transcript: DictationTranscript
    let onBegin: (_ keyboardLanguage: String?, _ locked: Bool) -> Void
    let onDrag: (CGSize) -> Void
    let onEnd: () -> Void
    let onCancel: () -> Void
    let onStop: () -> Void
    /// Finishing sends the message rather than leaving it in the field.
    let sendsOnFinish: Bool
}

nonisolated enum ComposerDictationPresentation {
    /// The dictated text shown in the field: the settled part, then the
    /// recognizer's current guess, joined onto the draft as it will be inserted.
    static func preview(draft: String, transcript: DictationTranscript) -> (settled: String, pending: String) {
        let settled = DictationTextMerge.merged(draft: draft, transcript: transcript.finalized)
        let full = DictationTextMerge.merged(draft: settled, transcript: transcript.volatile)
        return (settled, String(full.dropFirst(settled.count)))
    }

    /// A send or edit save in flight still owns the draft, so no new hold
    /// starts; one already running keeps its gesture so its release lands.
    static func admitsHold(isSending: Bool, isDictating: Bool) -> Bool {
        isDictating || !isSending
    }

    /// Dictation sends at once, except an edit (saving stays a separate
    /// decision), text that recognition didn't finish settling, or a composer
    /// something else changed during the hold (a restored rejected send, a
    /// late saved-draft load) that the person hasn't seen whole.
    static func sendsOnFinish(
        isEditing: Bool,
        isComplete: Bool = true,
        composerAtHoldStart: ComposerHoldSnapshot?,
        composerNow: ComposerHoldSnapshot
    ) -> Bool {
        !isEditing && isComplete && composerAtHoldStart == composerNow
    }

    /// The resting field says how to use it; once typing, it's the usual prompt.
    static func placeholder(offersDictation: Bool, isTyping: Bool) -> String {
        offersDictation && !isTyping
            ? L10n.string("Tap to type, hold to dictate")
            : L10n.string("Message")
    }
}

/// Conversation composer with attachment, emoji, text, send, and voice controls.
struct ComposerDisabledAction {
    let title: String
    let isEnabled: Bool
    let perform: () -> Void
}

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
    /// An action offered under `disabledMessage`, such as cancelling a blocked leave.
    var disabledAction: ComposerDisabledAction?
    var sendBlockedMessage: String?
    var textOverage: Int?
    let voiceRecordingActive: Bool
    let voiceRecordingLocked: Bool
    let voiceRecordingDurationSeconds: Double
    /// The latest microphone level while recording, 0...1.
    let voiceRecordingLevel: CGFloat
    let focusRequest: Int
    let dismissRequest: Int
    /// Reports text-input focus upward so the conversation can restore it
    /// after a cancelled interactive pop, and only then.
    var onInputFocusChange: (Bool) -> Void = { _ in }
    let mentionCandidates: [ComposerMentionCandidate]
    var submissionEnabled = true
    var submissionAccessibilityLabel = L10n.string("Send")
    var voiceMessagesEnabled = true
    /// Hold-to-dictate; nil where the feature is off or unsupported.
    var dictation: ComposerDictationBinding?
    var cameraAvailable = true
    var gifsAvailable = true
    var pollsAvailable = false
    var onCreatePoll: () -> Void = {}
    /// The conversation holds custom emoji this person can send.
    var customEmojiAvailable = false
    var onCustomEmoji: () -> Void = {}
    var stickersAvailable = false
    var onStickers: () -> Void = {}
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
    /// Where the current hold began (window coordinates) and how far the
    /// finger has moved since; they place the lock hint and the slide prompts.
    @State private var holdAnchor: CGPoint?
    @State private var holdTranslation: CGSize = .zero
    /// Each voice hold starts recording once; a slide-left cancel mustn't
    /// restart it while the finger is still down.
    @State private var voiceHoldStart: CGPoint?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body)
    private var fieldFontSize = BottomInputChromeLayout.fieldFontSize

    // The typed text keeps growing with Dynamic Type; the buttons around it
    // stop at the chrome cap so the field keeps its width.
    private var controlSize: CGFloat {
        WNChromeDynamicType.scaled(ComposerInputChrome.controlSize, at: dynamicTypeSize)
    }
    private var inlineSendSize: CGFloat {
        WNChromeDynamicType.scaled(ComposerInputChrome.sendButtonSize, at: dynamicTypeSize)
    }
    private var sideControlIconSize: CGFloat {
        WNChromeDynamicType.scaled(BottomInputChromeLayout.sideControlIconSize, at: dynamicTypeSize)
    }
    private var inlineSendIconSize: CGFloat {
        WNChromeDynamicType.scaled(BottomInputChromeLayout.inlineSendIconSize, at: dynamicTypeSize)
    }

    private var inputEnabled: Bool { disabledMessage == nil }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                if !mentionCandidates.isEmpty {
                    ComposerMentionPicker(candidates: mentionCandidates, onSelect: onMentionSelect)
                }

                if let notice = ComposerAvailabilityPresentation.sendBlockedNotice(
                    sendBlockedMessage: sendBlockedMessage,
                    hasSendableContent: hasSendableContent
                ) {
                    inactiveComposerMessage(notice)
                }

                if let textOverage = ComposerAvailabilityPresentation.textOverageNotice(
                    overage: textOverage,
                    disabledMessage: disabledMessage,
                    hasAudioDraft: audioDraft != nil,
                    voiceRecordingActive: voiceRecordingActive
                ) {
                    ComposerTextOverageLabel(overage: textOverage, trailingInset: controlSize / 2)
                }

                if ComposerAvailabilityPresentation.showsInput(disabledMessage: disabledMessage) {
                    bottomInputGlassContainer(spacing: ComposerInputChrome.rowSpacing) {
                        HStack(alignment: .bottom, spacing: ComposerInputChrome.rowSpacing) {
                            if ComposerVoiceChromePresentation.showsCancel(isActive: voiceRecordingActive) {
                                recordingCancelButton
                            } else if dictationActive, let dictation {
                                dictationCancelButton(dictation)
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
                                interactive: false
                            )
                        }
                    }
                } else if let disabledMessage {
                    VStack(spacing: 8) {
                        inactiveComposerMessage(disabledMessage)
                        if let disabledAction {
                            Button(disabledAction.title, action: disabledAction.perform)
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(!disabledAction.isEnabled)
                        }
                    }
                }
            }
            .padding(.horizontal, ComposerInputChrome.horizontalInset)
            .padding(.vertical, ComposerInputChrome.verticalInset)
        }
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .topLeading) { holdLockHintOverlay }
        .preservesKeyboardOnTap()
        .onChange(of: voiceRecordingLocked) { _, locked in
            // Locking swaps the voice icon for the send button, which ends
            // its gesture without an end event.
            if locked { voiceHoldStart = nil }
        }
        .onDisappear {
            // Search, message selection and the like replace the composer;
            // dictation must not keep listening, or send, behind them.
            if dictationActive { dictation?.onCancel() }
        }
        .fullScreenCover(isPresented: $showExpandedEditor) {
            ExpandedComposerEditor(
                draft: $draft,
                textOverage: textOverage,
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
                    gifsAvailable: gifsAvailable,
                    pollsAvailable: pollsAvailable,
                    customEmojiAvailable: customEmojiAvailable,
                    stickersAvailable: stickersAvailable
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
            .accessibilityShowsLargeContentViewer()
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
            .accessibilityShowsLargeContentViewer()
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
                    // Dictation hides the field without disabling hit-testing:
                    // the hold that started it is still tracking there.
                    composerTextEntry
                        .opacity(ComposerVoiceChromePresentation.textEntryOpacity(
                            isActive: voiceRecordingActive || dictationActive
                        ))
                        .allowsHitTesting(!voiceRecordingActive)
                        .accessibilityHidden(voiceRecordingActive || dictationActive)

                    if dictationActive, let dictation {
                        ComposerDictationInput(
                            draft: draft,
                            transcript: dictation.transcript,
                            isFinishing: dictation.state == .finishing,
                            fontSize: fieldFontSize
                        )
                        .allowsHitTesting(false)
                    } else if voiceRecordingActive {
                        ComposerVoiceRecordingStatus(
                            durationSeconds: voiceRecordingDurationSeconds,
                            isLocked: voiceRecordingLocked,
                            dragX: holdTranslation.width
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
                    Text(ComposerDictationPresentation.placeholder(
                        offersDictation: dictationGesture != nil,
                        isTyping: isTextInputFocused
                    ))
                        .font(.system(size: fieldFontSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        // Longer translations shrink rather than lose letters.
                        .minimumScaleFactor(0.5)
                        .padding(.top, BottomInputChromeLayout.fieldVerticalPadding)
                }

                ComposerTextInput(
                    text: $draft,
                    isFocused: $isTextInputFocused,
                    fontSize: fieldFontSize,
                    focusRequest: focusRequest &* 1_000 &+ localFocusRequest,
                    onPasteImage: onPasteImage,
                    dictation: dictationGesture,
                    blocksEditing: dictationActive
                )
            }
            .padding(.leading, BottomInputChromeLayout.fieldLeadingPadding)
            .frame(maxWidth: .infinity, alignment: .leading)

            if ComposerExpandedEditorPresentation.shouldShowExpandButton(for: draft, isDictating: dictationActive) {
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
        if let replyPreview {
            ComposerReplyPreviewView(
                preview: replyPreview,
                onCancel: onCancelReply
            )
        }

        if !preparedAttachments.isEmpty {
            MediaDraftStrip(
                attachments: preparedAttachments,
                onRemove: onRemovePreparedAttachment,
                onPreviewVisual: onPreviewPreparedMedia
            )
        }
    }

    private func dictationCancelButton(_ dictation: ComposerDictationBinding) -> some View {
        Button(action: dictation.onCancel) {
            sideCircleIcon(
                "xmark",
                weight: .semibold,
                size: sideControlIconSize,
                tone: .destructive
            )
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .accessibilityLabel(L10n.string("Cancel dictation"))
    }

    @ViewBuilder
    private func dictationTrailingControl(_ dictation: ComposerDictationBinding) -> some View {
        let appearance = ComposerSendButtonAppearance.colorScheme(colorScheme)
        switch dictation.state {
        case .listening(locked: true):
            Button(action: dictation.onStop) {
                Image(systemName: dictation.sendsOnFinish ? "arrow.up" : "checkmark")
                    .font(.system(size: inlineSendIconSize, weight: .bold))
                    .foregroundStyle(appearance.symbol.color)
                    .frame(width: inlineSendSize, height: inlineSendSize)
                    .background(Circle().fill(appearance.fill.color))
                    .frame(width: controlSize, height: controlSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                dictation.sendsOnFinish ? submissionAccessibilityLabel : L10n.string("Finish dictation")
            )
        case .finishing, .starting:
            ProgressView()
                .controlSize(.small)
                .frame(width: controlSize, height: controlSize)
        case .listening(locked: false), .idle:
            // Sliding up locks dictation, as it does a voice message.
            Image(systemName: "lock")
                .font(.system(size: sideControlIconSize * 0.8, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: controlSize, height: controlSize)
                .accessibilityHidden(true)
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
        .accessibilityShowsLargeContentViewer()
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
        .accessibilityShowsLargeContentViewer()
    }

    @ViewBuilder
    private var trailingActionSlot: some View {
        if dictationActive, let dictation {
            dictationTrailingControl(dictation)
        } else if ComposerVoiceChromePresentation.showsStop(
            isActive: voiceRecordingActive,
            isLocked: voiceRecordingLocked
        ) {
            let appearance = ComposerSendButtonAppearance.colorScheme(colorScheme)
            Button(action: onStopVoiceRecording) {
                Image(systemName: "arrow.up")
                    .font(.system(size: inlineSendIconSize, weight: .semibold))
                    .foregroundStyle(appearance.symbol.color)
                    .frame(width: inlineSendSize, height: inlineSendSize)
                    .background(Circle().fill(appearance.fill.color))
                    .frame(width: controlSize, height: controlSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(submissionAccessibilityLabel)
            .accessibilityShowsLargeContentViewer()
        } else if showsSend {
            sendButton
                .transition(.scale(scale: 0.88).combined(with: .opacity))
        } else if showsMic {
            // One view throughout the hold so its gesture survives: at rest
            // the icon, while recording a red bubble under the thumb that
            // follows the slide.
            let holding = voiceRecordingActive
            Image(systemName: holding ? "mic.fill" : "waveform")
                .font(.system(size: sideControlIconSize, weight: .semibold))
                .scaleEffect(holding ? 1.4 : 1)
                .foregroundStyle(
                    holding
                        ? Color.white
                        : inputEnabled
                            ? ComposerSideIconTone.primary.color
                            : ComposerSideIconTone.disabled.color
                )
                .frame(width: controlSize, height: controlSize)
                .background {
                    if holding {
                        VoiceRecordingBubble(level: voiceRecordingLevel)
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.5).combined(with: .opacity))
                    }
                }
                .offset(holding ? HoldGesturePolicy.thumbOffset(holdTranslation) : .zero)
                .animation(reduceMotion ? nil : .spring(duration: 0.2), value: holding)
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
            .compatibleInputCircleChrome(interactive: interactive)
    }

    private var hasSendableContent: Bool {
        hasAttachments || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSend: Bool {
        inputEnabled && sendBlockedMessage == nil && !isSending && hasSendableContent && submissionEnabled
    }

    private var showsSend: Bool {
        ComposerVoiceChromePresentation.showsSend(
            hasSendableContent: hasSendableContent,
            isActive: voiceRecordingActive
        )
    }

    private var dictationActive: Bool {
        dictation?.state.isActive ?? false
    }

    /// The hold stays installed while dictation runs, so the hold that
    /// started it keeps tracking.
    private var dictationGesture: ComposerDictationGesture? {
        guard let dictation, inputEnabled, audioDraft == nil, !voiceRecordingActive,
              ComposerDictationPresentation.admitsHold(isSending: isSending, isDictating: dictationActive)
        else { return nil }
        return ComposerDictationGesture(
            onBegan: { language, location in
                holdAnchor = location
                holdTranslation = .zero
                dictation.onBegin(language, false)
            },
            onChanged: { translation in
                holdTranslation = translation
                dictation.onDrag(translation)
            },
            onEnded: {
                holdTranslation = .zero
                dictation.onEnd()
            },
            onCancelled: {
                holdTranslation = .zero
                dictation.onCancel()
            },
            onAccessibilityDictate: { language in dictation.onBegin(language, true) }
        )
    }

    /// The lock hint shows while a hold is under the thumb, until it locks.
    private var showsLockHint: Bool {
        if voiceRecordingActive { return !voiceRecordingLocked }
        guard let state = dictation?.state else { return false }
        return state == .starting(locked: false) || state == .listening(locked: false)
    }

    /// Floats the lock hint above where the thumb went down, outside the
    /// composer's own bounds.
    private var holdLockHintOverlay: some View {
        GeometryReader { proxy in
            if showsLockHint, let holdAnchor {
                HoldLockHint(progress: HoldGesturePolicy.lockProgress(holdTranslation))
                    .dynamicTypeSize(...WNChromeDynamicType.maximum)
                    .fixedSize()
                    // Anchor the bottom edge, so a taller hint grows away from the thumb.
                    .frame(height: 0, alignment: .bottom)
                    .position(
                        x: holdAnchor.x - proxy.frame(in: .global).minX,
                        y: voiceRecordingActive
                            ? -VoiceRecordingBubbleMetrics.lockHintGap
                            : -HoldLockHint.gapAboveComposer
                    )
                    .transition(
                        reduceMotion ? .opacity : .scale(scale: 0.6, anchor: .bottom).combined(with: .opacity)
                    )
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.25), value: showsLockHint)
        .allowsHitTesting(false)
    }

    private var showsMic: Bool {
        voiceMessagesEnabled && ((!hasSendableContent && !isSending) || voiceRecordingActive)
    }

    private var voiceGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                guard inputEnabled else { return }
                if voiceHoldStart != value.startLocation {
                    voiceHoldStart = value.startLocation
                    holdAnchor = value.startLocation
                    holdTranslation = .zero
                    onVoicePressBegan()
                }
                holdTranslation = value.translation
                onVoiceDragChanged(value.translation)
            }
            .onEnded { value in
                voiceHoldStart = nil
                holdTranslation = .zero
                guard inputEnabled else { return }
                // A fast slide can cross the cancel threshold only in the
                // release event.
                onVoiceDragChanged(value.translation)
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
        case .stickers:
            onStickers()
        case .customEmoji:
            onCustomEmoji()
        case .location:
            onShareLocation()
        case .contact:
            onShareContact()
        case .poll:
            onCreatePoll()
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

private struct ComposerDictationInput: View {
    let draft: String
    let transcript: DictationTranscript
    let isFinishing: Bool
    let fontSize: CGFloat

    var body: some View {
        let preview = ComposerDictationPresentation.preview(draft: draft, transcript: transcript)
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "mic.fill")
                .font(.system(size: fontSize * 0.9, weight: .semibold))
                .foregroundStyle(.red)
                .symbolEffect(.pulse, options: .repeating, isActive: !isFinishing)
                .accessibilityHidden(true)

            Group {
                if preview.settled.isEmpty, preview.pending.isEmpty {
                    Text(L10n.string("Listening…"))
                        .foregroundStyle(.secondary)
                } else {
                    Text(Self.attributed(settled: preview.settled, pending: preview.pending))
                        .truncationMode(.head)
                }
            }
            .font(.system(size: fontSize))
            .lineLimit(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 14)
        .padding(.vertical, BottomInputChromeLayout.fieldVerticalPadding)
        .frame(maxWidth: .infinity, minHeight: ComposerInputChrome.controlSize, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string("Listening…"))
        .accessibilityValue(Text(verbatim: preview.settled + preview.pending))
    }

    private static func attributed(settled: String, pending: String) -> AttributedString {
        var text = AttributedString(settled)
        var guess = AttributedString(pending)
        guess.foregroundColor = .secondary
        text.append(guess)
        return text
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

    /// Dictation owns the field, so its hidden controls can't be tapped.
    static func shouldShowExpandButton(for text: String, isDictating: Bool = false) -> Bool {
        guard !isDictating else { return false }
        return text.count >= minimumExpandCharacterCount
            || text.contains(where: \.isNewline)
    }
}

private struct ComposerTextOverageLabel: View {
    let overage: Int
    var trailingInset: CGFloat = 12

    var body: some View {
        Text(L10n.plural("%lld characters over", Int64(overage)))
            .font(.footnote.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(.red)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, trailingInset)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

private struct ExpandedComposerEditor: View {
    @Binding var draft: String
    let textOverage: Int?
    let canSend: Bool
    let onDone: () -> Void
    let onSend: () -> Void

    @FocusState private var focused: Bool

    private let margin: CGFloat = 16

    var body: some View {
        NavigationStack {
            TextEditor(text: $draft)
                .font(.body)
                .padding(margin)
                .focused($focused)
                .safeAreaInset(edge: .bottom) {
                    if let textOverage {
                        ComposerTextOverageLabel(overage: textOverage, trailingInset: 5)
                            .padding(.horizontal, margin)
                            .padding(.bottom, 8)
                    }
                }
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
