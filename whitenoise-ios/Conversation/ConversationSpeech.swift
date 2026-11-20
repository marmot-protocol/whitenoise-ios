import AVFoundation
import Foundation
import MarmotKit
import Observation
import Speech
import SwiftUI

enum MessageSpeechAction: String, Hashable {
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

/// The navigation stack owns speech so a profile push leaves it running and
/// popping past a covered conversation still cancels it.
struct ConversationSpeechSession<Route: Equatable>: ViewModifier {
    let speech: ConversationSpeech
    let route: Route
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .environment(speech)
            .onDisappear { speech.reset() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { speech.reset() }
            }
            .onChange(of: route) { speech.reset() }
    }
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

    private(set) var readingID: String?
    private(set) var readingProgress = 0.0
    private(set) var transcribingID: String?
    private(set) var transcripts: [String: Transcript] = [:]
    var availableAudio: (recording: Recording, source: LocalVoiceAttachment, scope: Scope)?
    private var transcribingRecording: Recording?
    @ObservationIgnored private var readingPreparation: Task<Void, Never>?
    @ObservationIgnored private var activeUtterance: (id: ObjectIdentifier, length: Int)?
    @ObservationIgnored private var synthesizer: AVSpeechSynthesizer?
    @ObservationIgnored private var transcription: Task<Void, Never>?
    @ObservationIgnored private var requestID: UUID?

    func read(markdown: String, id: String, onEmpty: @escaping () -> Void) {
        stopReading()
        readingID = id
        readingPreparation = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let prepared = await Self.prepareReading(markdown)
            guard !Task.isCancelled, let self else { return }
            readingPreparation = nil
            guard prepared.length > 0 else {
                readingID = nil
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
        readingID = nil
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

    func transcribe(id: String, recording: Recording, data: @escaping () async throws -> Data,
                    verifiedScope: @escaping () async -> Scope?, onError: @escaping () -> Void) {
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
                guard let scope = await verifiedScope(), !Task.isCancelled, requestID == request else { return }
                transcripts[id] = Transcript(scope: scope, recording: recording, text: text)
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled, requestID == request { onError() }
            }
        }
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

    func prune(visibleMessage: (String) -> Bool, audioMatches: (String, Recording) -> Bool) {
        if let readingID, !visibleMessage(readingID) { stopReading() }
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
        availableAudio = nil
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
enum LocalVoiceAttachment {
    #if DEBUG
    case bundled(URL, target: AttachmentLocalTargetFfi)
    #endif
    case retained(account: String, group: String, client: MarmotClient, target: AttachmentLocalTargetFfi)

    var target: AttachmentLocalTargetFfi {
        switch self {
        #if DEBUG
        case .bundled(_, let target): target
        #endif
        case .retained(_, _, _, let target): target
        }
    }

    static func resolve(_ media: MessageMediaAttachment, group: String, app: AppState, fixture: Bool) async throws -> Self? {
        #if DEBUG
        if fixture {
            guard let target = media.localTarget, let url = ChatPreviewMedia.url(media.fileName) else { return nil }
            return .bundled(url, target: target)
        }
        #endif
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
        let source = Self.retained(account: account, group: group, client: client, target: target)
        return try await source.isAvailable(in: app) ? source : nil
    }

    private func isAvailable(in app: AppState) async throws -> Bool {
        switch self {
        #if DEBUG
        case .bundled: return true
        #endif
        case let .retained(account, group, client, target):
            guard app.client === client, app.activeAccountRef == account else { return false }
            let assets = try await client.marmot.attachmentLocalAssets(accountRef: account, groupIdHex: group, targets: [target])
            guard let asset = assets.first, asset.reference != nil,
                  asset.byteCount > 0, asset.byteCount <= MessageMediaAttachment.audioAnalysisByteLimit else { return false }
            return !Task.isCancelled && app.client === client && app.activeAccountRef == account
        }
    }

    func data(in app: AppState) async throws -> Data {
        switch self {
        #if DEBUG
        case .bundled(let url, _):
            return try Data(contentsOf: url, options: .mappedIfSafe)
        #endif
        case let .retained(account, group, client, target):
            guard app.activeAccountRef == account, app.client === client,
                  let data = try await client.attachmentData(accountRef: account, groupID: group, target: target,
                                                             previewByteLimit: MessageMediaAttachment.audioAnalysisByteLimit),
                  !Task.isCancelled, app.activeAccountRef == account, app.client === client else {
                throw AttachmentReadError.unavailable
            }
            return data
        }
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
