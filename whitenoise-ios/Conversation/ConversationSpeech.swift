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

    struct Transcript {
        var scope: Scope
        let attachmentID: String
        let text: String
        var visible = true
    }

    private(set) var readingID: String?
    private(set) var readingProgress = 0.0
    private(set) var transcribingID: String?
    private(set) var transcripts: [String: Transcript] = [:]
    var availableAudio: (id: String, source: LocalVoiceAttachment, scope: Scope)?
    private var transcribingAttachmentID: String?
    @ObservationIgnored private var readingPreparation: Task<Void, Never>?
    @ObservationIgnored private var activeUtterance: (id: ObjectIdentifier, length: Int)?
    @ObservationIgnored private var synthesizer: AVSpeechSynthesizer?
    @ObservationIgnored private var transcription: Task<Void, Never>?
    @ObservationIgnored private var requestID: UUID?

    func read(markdown: String, id: String) {
        stopReading()
        readingID = id
        readingPreparation = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let prepared = await Self.prepareReading(markdown)
            guard !Task.isCancelled, let self else { return }
            readingPreparation = nil
            guard prepared.length > 0 else {
                readingID = nil
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

    func transcribe(id: String, attachmentID: String, data: @escaping () async throws -> Data,
                    verifiedScope: @escaping () async -> Scope?, onError: @escaping () -> Void) {
        guard #available(iOS 26, *), transcription == nil else { return }
        let request = UUID()
        requestID = request
        transcribingID = id
        transcribingAttachmentID = attachmentID
        transcription = Task {
            defer {
                if requestID == request {
                    transcribingID = nil
                    transcribingAttachmentID = nil
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
                transcripts[id] = Transcript(scope: scope, attachmentID: attachmentID, text: text)
            } catch {
                if !Task.isCancelled, requestID == request { onError() }
            }
        }
    }

    /// A revised attachment presentation immediately hides derived text. Restore
    /// only recordings whose original slots are still held in the opening route.
    func revalidate(in scope: Scope, isHeld: (String, String) async -> Bool?) async {
        if let running = requestID, let transcribingID, let transcribingAttachmentID,
           await isHeld(transcribingID, transcribingAttachmentID) == false,
           !Task.isCancelled, requestID == running {
            cancelTranscription()
        }
        for (id, transcript) in transcripts where transcript.scope != scope {
            guard !Task.isCancelled else { return }
            let held: Bool
            if transcript.scope.route == scope.route {
                guard let result = await isHeld(id, transcript.attachmentID) else { return }
                held = result
            } else {
                held = false
            }
            guard !Task.isCancelled else { return }
            guard transcripts[id]?.scope == transcript.scope, transcripts[id]?.attachmentID == transcript.attachmentID else { continue }
            if held {
                transcripts[id]?.scope = scope
            } else {
                transcripts.removeValue(forKey: id)
            }
        }
    }

    func setTranscriptVisible(_ visible: Bool, id: String) {
        transcripts[id]?.visible = visible
    }

    func prune(visibleMessage: (String) -> Bool, audioID: (String) -> String?) {
        if let readingID, !visibleMessage(readingID) { stopReading() }
        if let transcribingID, audioID(transcribingID) != transcribingAttachmentID { cancelTranscription() }
        let removed = transcripts.compactMap { id, value in audioID(id) == value.attachmentID ? nil : id }
        for id in removed { transcripts.removeValue(forKey: id) }
    }

    private func cancelTranscription() {
        requestID = nil
        transcription?.cancel()
        transcription = nil
        transcribingID = nil
        transcribingAttachmentID = nil
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
struct LocalVoiceAttachment {
    private let account: String
    private let group: String
    private let client: MarmotClient
    private let target: AttachmentLocalTargetFfi

    static func resolve(_ media: MessageMediaAttachment, group: String, app: AppState) async -> Self? {
        guard let account = app.activeAccountRef, let client = try? app.currentMarmotClient() else { return nil }
        let target: AttachmentLocalTargetFfi
        if let original = media.localTarget {
            target = original
        } else if let hint = media.sourceHint, let resolved = try? await client.resolveAttachmentTarget(
            accountRef: account, groupID: group, hint: hint) {
            target = resolved
        } else {
            return nil
        }
        let source = Self(account: account, group: group, client: client, target: target)
        return await source.isAvailable(in: app) ? source : nil
    }

    func isAvailable(in app: AppState) async -> Bool {
        guard app.client === client, app.activeAccountRef == account else { return false }
        let assets = try? await client.marmot.attachmentLocalAssets(accountRef: account, groupIdHex: group, targets: [target])
        guard let asset = assets?.first, asset.reference != nil,
              asset.byteCount > 0, asset.byteCount <= MessageMediaAttachment.audioAnalysisByteLimit else { return false }
        return !Task.isCancelled && app.client === client && app.activeAccountRef == account
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
