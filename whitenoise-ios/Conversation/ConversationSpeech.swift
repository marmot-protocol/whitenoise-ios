import AVFoundation
import Foundation
import MarmotKit
import Observation
import Speech
import SwiftUI

nonisolated enum MessageSpeechAction: String, Hashable {
    case read, stop, transcribe, transcribing, show, hide, copy

    var title: LocalizedStringKey {
        switch self {
        case .read: "Read Aloud"
        case .stop: "Stop Reading"
        case .transcribe: "Transcribe"
        case .transcribing: "Transcribing…"
        case .show: "Show Transcript"
        case .hide: "Hide Transcript"
        case .copy: "Copy Transcript"
        }
    }

    var symbol: String {
        switch self {
        case .read: "speaker.wave.2"
        case .stop: "stop.fill"
        case .transcribe, .show: "text.bubble"
        case .transcribing: "waveform"
        case .hide: "text.bubble.fill"
        case .copy: "doc.on.doc"
        }
    }
}

nonisolated enum MessageSpeechPresentation {
    static func hasBlankText(_ record: AppMessageRecordFfi) -> Bool {
        !ContentSanitizer.hasNonWhitespaceText(record.plaintext)
    }

    static func receivedAudio(for record: AppMessageRecordFfi, myAccountID: String?, media: [MessageMediaAttachment]) -> MessageMediaAttachment? {
        guard !MessageOwnership.isMine(direction: record.direction, sender: record.sender, myAccountId: myAccountID),
              media.count == 1, let audio = media.first, audio.kind == .audio, audio.rejectionKind == nil else { return nil }
        return audio
    }

    static func textActions(for record: AppMessageRecordFfi, myAccountID: String?, standaloneEmoji: @autoclosure () -> Bool,
                            hasSpokenText: @autoclosure () -> Bool) -> [MessageSpeechAction] {
        guard !MessageOwnership.isMine(direction: record.direction, sender: record.sender, myAccountId: myAccountID), !hasBlankText(record) else { return [] }
        switch MessageSemantics.classify(record) {
        case .chat, .reply, .media:
            guard SharedLocationText.location(from: record.plaintext) == nil,
                  RemoteGiphyMedia.parse(wireText: record.plaintext) == nil else { return [] }
            return !standaloneEmoji() && hasSpokenText() ? [.read] : []
        default: return []
        }
    }

    static func voiceActions(isTranscribing: Bool, transcriptVisible: Bool?, offersTranscribe: Bool) -> [MessageSpeechAction] {
        if isTranscribing { return [.transcribing] }
        if let transcriptVisible { return transcriptVisible ? [.hide, .copy] : [.show] }
        return offersTranscribe ? [.transcribe] : []
    }
}

/// The navigation stack owns speech so a profile push leaves it running and
/// popping past a covered conversation still cancels it.
struct ConversationSpeechSession<Route: Equatable>: ViewModifier {
    let speech: ConversationSpeech
    let route: Route
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .environment(speech)
            .background { SpeechSessionLifetime(speech: speech).frame(width: 0, height: 0) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { speech.reset() }
            }
            .onChange(of: route) { speech.reset() }
    }
}

/// A full-screen cover can hide the stack without removing it. End speech
/// when SwiftUI dismantles the stack, including while a detail covers the chat.
private struct SpeechSessionLifetime: UIViewRepresentable {
    let speech: ConversationSpeech

    func makeCoordinator() -> ConversationSpeech { speech }
    func makeUIView(context: Context) -> UIView { UIView(frame: .zero) }
    func updateUIView(_ view: UIView, context: Context) {}
    static func dismantleUIView(_ view: UIView, coordinator: ConversationSpeech) { coordinator.reset() }
}

@Observable @MainActor
final class ConversationSpeech: NSObject, AVSpeechSynthesizerDelegate {
    struct Route: Equatable {
        let groupID: String
        let modelID: ObjectIdentifier?
        let account: String?
        let runtimeGeneration: Int
    }

    struct Scope: Equatable {
        let route: Route
        let revision: Int
    }

    struct RetentionCheck: Equatable {
        let scope: Scope
        let publication: UUID?
    }

    private var lastPublication: UUID?
    func retentionCheck(in scope: Scope) -> RetentionCheck {
        RetentionCheck(scope: scope, publication: lastPublication)
    }

    struct Recording: Equatable {
        let displayID: String
        let target: AttachmentLocalTargetFfi

        func matches(_ media: MessageMediaAttachment?) -> Bool {
            guard let media, media.id == displayID else { return false }
            if let direct = media.localTarget { return direct == target }
            return media.sourceHint == AttachmentSourceHint(messageID: target.messageIdHex, slot: target.attachmentIndex)
        }
    }

    struct Transcript {
        var scope: Scope
        let recording: Recording
        let text: String
        var visible = true
        var verified = true

        func isVerified(in current: Scope) -> Bool { verified && scope == current }

        func revalidated(held: Bool?, in current: Scope) -> Self? {
            guard held != false, scope.route == current.route else { return nil }
            var next = self
            next.verified = held == true
            if next.verified { next.scope = current }
            return next
        }
    }

    private var reading: (id: String, sourceText: String)?
    var readingID: String? { reading?.id }
    private(set) var readingProgress = 0.0
    private(set) var transcribingID: String?
    private(set) var transcripts: [String: Transcript] = [:]
    struct VoiceRequest: Equatable {
        let scope: Scope
        let messageID: String
        let attachmentID: String?
        let target: AttachmentLocalTargetFfi?
        let sourceHint: AttachmentSourceHint?
    }

    enum VoiceAvailability {
        case available(Recording, LocalVoiceAttachment)
        case unavailable(String)
    }

    var checkedVoice: (request: VoiceRequest, result: VoiceAvailability)?
    private var transcribingRecording: Recording?
    @ObservationIgnored private var readingPreparation: Task<Void, Never>?
    @ObservationIgnored private var activeUtterance: (id: ObjectIdentifier, length: Int)?
    @ObservationIgnored private var synthesizer: AVSpeechSynthesizer?
    @ObservationIgnored private var transcription: Task<Void, Never>?
    @ObservationIgnored private var requestID: UUID?

    func read(markdown: String, id: String, sourceText: String, onEmpty: @escaping () -> Void) {
        stopReading()
        reading = (id, sourceText)
        readingPreparation = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let prepared = await Self.prepareReading(markdown)
            guard !Task.isCancelled, let self else { return }
            readingPreparation = nil
            guard prepared.length > 0 else {
                reading = nil
                onEmpty()
                return
            }
            let speaker = AVSpeechSynthesizer()
            speaker.usesApplicationAudioSession = false
            speaker.delegate = self
            let utterance = AVSpeechUtterance(string: prepared.text)
            activeUtterance = (ObjectIdentifier(utterance), prepared.length)
            synthesizer = speaker
            speaker.speak(utterance)
        }
    }

    @concurrent
    nonisolated private static func prepareReading(_ markdown: String) async -> (text: String, length: Int) {
        let text = (try? AttributedString(markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))).map { String($0.characters) } ?? markdown
        let spoken = ContentSanitizer.textRun(text).trimmingCharacters(in: .whitespacesAndNewlines)
        return (spoken, spoken.utf16.count)
    }

    func stopReading() {
        readingPreparation?.cancel()
        readingPreparation = nil
        synthesizer?.delegate = nil
        synthesizer?.stopSpeaking(at: .immediate)
        synthesizer = nil
        activeUtterance = nil
        reading = nil
        readingProgress = 0
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                        willSpeakRangeOfSpeechString range: NSRange, utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, let activeUtterance, activeUtterance.id == id, activeUtterance.length > 0 else { return }
            let progress = Double(min(NSMaxRange(range), activeUtterance.length)) / Double(activeUtterance.length)
            readingProgress = max(readingProgress, progress)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finishReading(ObjectIdentifier(utterance))
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finishReading(ObjectIdentifier(utterance))
    }

    nonisolated private func finishReading(_ id: ObjectIdentifier) {
        Task { @MainActor [weak self] in
            guard let self, activeUtterance?.id == id else { return }
            stopReading()
        }
    }

    func transcribe(id: String, recording: Recording, scope: Scope, data: @escaping () async throws -> Data,
                    isCurrent: @escaping () -> Bool, onError: @escaping () -> Void) {
        guard #available(iOS 26, *), transcription == nil else { return }
        let request = UUID()
        requestID = request
        transcribingID = id
        transcribingRecording = recording
        transcription = Task {
            defer {
                if requestID == request {
                    transcribingID = nil
                    transcribingRecording = nil
                    transcription = nil
                    requestID = nil
                }
            }
            do {
                let bytes = try await data()
                try Task.checkCancellation()
                let text = try await LocalVoiceRecognition.transcript(data: bytes)
                try Task.checkCancellation()
                guard requestID == request, isCurrent() else { return }
                stageTranscript(text, id: id, recording: recording, scope: scope)
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled, requestID == request { onError() }
            }
        }
    }

    /// Keep recognized words hidden until a check of their original slot completes.
    /// Publication wakes the check even if the attachment revision changed during recognition.
    func stageTranscript(_ text: String, id: String, recording: Recording, scope: Scope) {
        transcripts[id] = Transcript(scope: scope, recording: recording, text: text, verified: false)
        lastPublication = UUID()
    }

    /// A revised attachment presentation immediately hides derived text. Restore
    /// only recordings whose original slots are still held in the opening route.
    func revalidate(in scope: Scope, isHeld: (String, Recording) async -> Bool?) async {
        if let running = requestID, let transcribingID, let transcribingRecording,
           await isHeld(transcribingID, transcribingRecording) == false,
           !Task.isCancelled, requestID == running {
            cancelTranscription()
        }
        for (id, transcript) in transcripts where !transcript.isVerified(in: scope) {
            guard !Task.isCancelled else { return }
            let held = transcript.scope.route == scope.route ? await isHeld(id, transcript.recording) : false
            guard !Task.isCancelled else { return }
            guard transcripts[id]?.scope == transcript.scope, transcripts[id]?.recording == transcript.recording else { continue }
            updateRetention(held, id: id, recording: transcript.recording, scope: scope)
        }
    }

    func updateRetention(_ held: Bool?, id: String, recording: Recording, scope: Scope) {
        guard let transcript = transcripts[id], transcript.recording == recording else { return }
        transcripts[id] = transcript.revalidated(held: held, in: scope)
    }

    func setTranscriptVisible(_ visible: Bool, id: String) {
        transcripts[id]?.visible = visible
    }

    func prune(currentText: (String) -> String?, audioMatches: (String, Recording) -> Bool) {
        if let reading, currentText(reading.id) != reading.sourceText { stopReading() }
        if let transcribingID, let transcribingRecording, !audioMatches(transcribingID, transcribingRecording) { cancelTranscription() }
        let removed = transcripts.compactMap { id, value in audioMatches(id, value.recording) ? nil : id }
        for id in removed { transcripts.removeValue(forKey: id) }
    }

    private func cancelTranscription() {
        requestID = nil
        transcription?.cancel()
        transcription = nil
        transcribingID = nil
        transcribingRecording = nil
    }

    func reset() {
        stopReading()
        cancelTranscription()
        transcripts.removeAll()
        checkedVoice = nil
    }
}

@available(iOS 26, *)
nonisolated enum LocalVoiceRecognition {
    static func recognizer() async -> DictationRecognizer? {
        await DictationRecognizer.resolve(Locale.preferredLanguages, installedOnly: true)
    }

    static func transcript(data: Data) async throws -> String {
        guard let recognizer = await recognizer(),
              let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [recognizer.module])
        else { throw AttachmentReadError.unavailable }
        let input = try VoiceTranscriptionInput(data: data, format: format)
        let buffers = AsyncThrowingStream(unfolding: { try await input.next() })
        let analyzer = SpeechAnalyzer(modules: [recognizer.module])
        return try await withTaskCancellationHandler {
            async let transcript = finalizedText(from: recognizer)
            do {
                try Task.checkCancellation()
                guard let end = try await analyzer.analyzeSequence(buffers) else { throw AttachmentReadError.unavailable }
                try await analyzer.finalizeAndFinish(through: end)
            } catch {
                await analyzer.cancelAndFinishNow()
                throw error
            }
            return try await transcript
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    private static func finalizedText(from recognizer: DictationRecognizer) async throws -> String {
        var segments: [String] = []
        for try await (text, isFinal) in recognizer.results() {
            try Task.checkCancellation()
            if isFinal { segments.append(text) }
        }
        let text = segments.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AttachmentReadError.unavailable }
        return text
    }
}

/// A reference to bytes already held for this attachment. Neither checking
/// availability nor reading the original slot can admit a download or retry.
@MainActor
struct LocalVoiceAttachment {
    private let account: String
    private let group: String
    private let client: MarmotClient
    let target: AttachmentLocalTargetFfi

    enum SizeError: Error {
        case empty, tooLarge

        var message: String {
            switch self {
            case .empty: L10n.string("Couldn’t transcribe this recording.")
            case .tooLarge: L10n.string("This recording is too large to transcribe.")
            }
        }
    }

    static func validateSize(_ byteCount: UInt64) throws {
        guard byteCount > 0 else { throw SizeError.empty }
        guard byteCount <= MessageMediaAttachment.audioAnalysisByteLimit else { throw SizeError.tooLarge }
    }

    static func resolve(_ media: MessageMediaAttachment, group: String, app: AppState) async throws -> Self? {
        guard let account = app.activeAccountRef else { return nil }
        let client = try app.currentMarmotClient()
        let target: AttachmentLocalTargetFfi
        if let original = media.localTarget {
            target = original
        } else if let hint = media.sourceHint {
            guard let resolved = try await client.findAttachmentTarget(accountRef: account, groupID: group, hint: hint) else { return nil }
            target = resolved
        } else {
            return nil
        }
        let source = Self(account: account, group: group, client: client, target: target)
        return try await source.isAvailable(in: app) ? source : nil
    }

    private func isAvailable(in app: AppState) async throws -> Bool {
        guard app.client === client, app.activeAccountRef == account else { return false }
        let assets = try await client.marmot.attachmentLocalAssets(accountRef: account, groupIdHex: group, targets: [target])
        guard !Task.isCancelled, app.client === client, app.activeAccountRef == account else { throw CancellationError() }
        guard let asset = assets.first, asset.reference != nil else { return false }
        try Self.validateSize(asset.byteCount)
        return true
    }

    func data(in app: AppState) async throws -> Data {
        guard app.activeAccountRef == account, app.client === client,
              let data = try await client.attachmentData(accountRef: account, groupID: group, target: target,
                                                         previewByteLimit: MessageMediaAttachment.audioAnalysisByteLimit),
              !Task.isCancelled, app.activeAccountRef == account, app.client === client else {
            throw AttachmentReadError.unavailable
        }
        return data
    }
}

struct MessageReadingProgress: View {
    let speech: ConversationSpeech

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "speaker.wave.2.fill").font(.caption2)
            ProgressView(value: speech.readingProgress)
                .progressViewStyle(.linear)
                .tint(MessageBubblePalette.receivedForeground.opacity(0.75))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Read Aloud")
        .accessibilityValue(speech.readingProgress.formatted(.percent.precision(.fractionLength(0))))
    }
}
