import AVFoundation
import Foundation
import Observation
import OSLog
import Speech
import Synchronization

nonisolated private enum DictationDiagnostics {
    static let log = Logger(subsystem: "dev.ipf.whitenoise.ios", category: "dictation")
}

/// The on-device recognizer for one language. `SpeechTranscriber` is Apple's
/// newer model; `DictationTranscriber` is the keyboard-dictation model, which
/// more devices and languages support.
@available(iOS 26.0, *)
nonisolated enum DictationRecognizer: Sendable {
    case speech(SpeechTranscriber)
    case dictation(DictationTranscriber)

    var module: any SpeechModule {
        switch self {
        case .speech(let transcriber): transcriber
        case .dictation(let transcriber): transcriber
        }
    }

    /// The first candidate language either model supports, preferring
    /// `SpeechTranscriber` for each language before moving to the next.
    static func resolve(_ identifiers: [String]) async -> DictationRecognizer? {
        let speechAvailable = SpeechTranscriber.isAvailable
        for identifier in identifiers {
            let requested = Locale(identifier: identifier)
            if speechAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) {
                return .speech(SpeechTranscriber(
                    locale: locale,
                    transcriptionOptions: [],
                    reportingOptions: [.volatileResults, .fastResults],
                    attributeOptions: []
                ))
            }
            if let locale = await DictationTranscriber.supportedLocale(equivalentTo: requested) {
                return .dictation(DictationTranscriber(
                    locale: locale,
                    contentHints: [.shortForm],
                    transcriptionOptions: [.punctuation],
                    reportingOptions: [.volatileResults, .frequentFinalization],
                    attributeOptions: []
                ))
            }
        }
        return nil
    }

    var locale: Locale? {
        switch self {
        case .speech(let transcriber): transcriber.selectedLocales.first
        case .dictation(let transcriber): transcriber.selectedLocales.first
        }
    }

    /// Recognized text and whether it is final, in the order iOS reports it.
    func results() -> AsyncThrowingStream<(text: String, isFinal: Bool), Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    switch self {
                    case .speech(let transcriber):
                        for try await result in transcriber.results {
                            continuation.yield((String(result.text.characters), result.isFinal))
                        }
                    case .dictation(let transcriber):
                        for try await result in transcriber.results {
                            continuation.yield((String(result.text.characters), result.isFinal))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Downloads the speech model for a language. iOS owns the download and
/// shares the model between apps; it comes from Apple, not from White Noise.
@available(iOS 26.0, *)
@MainActor
@Observable
final class DictationModelInstaller {
    enum Status: Equatable {
        case unknown
        case checking
        case ready
        case notInstalled
        case downloading
        case unsupportedLanguage
        case failed
    }

    static let shared = DictationModelInstaller()

    private(set) var status: Status = .unknown
    @ObservationIgnored private(set) var currentInstall: Task<Bool, Never>?

    /// Reports whether the model for the best-matching language is installed.
    func refresh(localeIdentifiers: [String]) async {
        guard currentInstall == nil else { return }
        status = .checking
        guard let recognizer = await DictationRecognizer.resolve(localeIdentifiers) else {
            status = .unsupportedLanguage
            return
        }
        guard currentInstall == nil else { return }
        status = Self.status(for: await AssetInventory.status(forModules: [recognizer.module]))
    }

    /// Starts downloading the model unless it is installed or downloading.
    @discardableResult
    func install(localeIdentifiers: [String]) -> Task<Bool, Never> {
        if let currentInstall { return currentInstall }
        status = .downloading
        let task = Task { @MainActor [weak self] () -> Bool in
            let succeeded = await Self.download(localeIdentifiers: localeIdentifiers)
            guard let self else { return succeeded }
            self.currentInstall = nil
            await self.refresh(localeIdentifiers: localeIdentifiers)
            if !succeeded, self.status != .unsupportedLanguage {
                self.status = .failed
            }
            return succeeded
        }
        currentInstall = task
        return task
    }

    private static func download(localeIdentifiers: [String]) async -> Bool {
        guard let recognizer = await DictationRecognizer.resolve(localeIdentifiers) else { return false }
        do {
            if let locale = recognizer.locale,
               !(await AssetInventory.reservedLocales).contains(locale) {
                // Keeps the model on device; failing only means iOS may
                // reclaim it later.
                _ = try? await AssetInventory.reserve(locale: locale)
            }
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [recognizer.module]) {
                try await request.downloadAndInstall()
            }
            return await AssetInventory.status(forModules: [recognizer.module]) == .installed
        } catch {
            DictationDiagnostics.log.error("Speech model download failed: \(String(describing: type(of: error)), privacy: .public)")
            return false
        }
    }

    private static func status(for assetStatus: AssetInventory.Status) -> Status {
        switch assetStatus {
        case .installed: .ready
        case .downloading: .downloading
        case .supported: .notInstalled
        case .unsupported: .unsupportedLanguage
        @unknown default: .unsupportedLanguage
        }
    }
}

@available(iOS 26.0, *)
enum SpeechAnalyzerDictation {
    /// Starts on-device transcription from the microphone.
    static func start(
        localeIdentifiers: [String],
        onUpdate: @escaping @MainActor (DictationTranscript) -> Void
    ) async throws -> DictationSession {
        guard await VoiceRecordingMicrophone.live.requestPermission() else {
            throw DictationFailure.permissionDenied
        }
        try Task.checkCancellation()
        guard let recognizer = await DictationRecognizer.resolve(localeIdentifiers) else {
            throw DictationFailure.unsupportedLanguage
        }
        switch await AssetInventory.status(forModules: [recognizer.module]) {
        case .installed:
            break
        case .unsupported:
            throw DictationFailure.unsupportedLanguage
        case .supported, .downloading:
            DictationModelInstaller.shared.install(localeIdentifiers: localeIdentifiers)
            throw DictationFailure.modelDownloading
        @unknown default:
            throw DictationFailure.unsupportedLanguage
        }
        try Task.checkCancellation()

        let lease: VoiceAudioSession.Lease
        do {
            lease = try VoiceAudioSession.configureForRecording()
        } catch {
            throw DictationFailure.startFailed
        }
        let pipeline = SpeechAnalyzerPipeline(recognizer: recognizer)
        do {
            try await pipeline.start(onUpdate: onUpdate)
        } catch {
            await pipeline.cancel()
            VoiceAudioSession.deactivate(lease)
            DictationDiagnostics.log.error("Dictation failed to start: \(String(describing: error), privacy: .public)")
            throw DictationFailure.startFailed
        }
        return DictationSession(
            finish: {
                let text = await pipeline.finish()
                VoiceAudioSession.deactivate(lease)
                return text
            },
            cancel: {
                await pipeline.cancel()
                VoiceAudioSession.deactivate(lease)
            }
        )
    }
}

/// Microphone → format conversion → `SpeechAnalyzer` → transcript.
@available(iOS 26.0, *)
@MainActor
private final class SpeechAnalyzerPipeline {
    /// How long the recognizer may take to settle the last words after release.
    private static let finishTimeoutNanoseconds: UInt64 = 4_000_000_000

    private let recognizer: DictationRecognizer
    private let analyzer: SpeechAnalyzer
    private let capture = DictationAudioCapture()
    private let input: AsyncStream<AnalyzerInput>
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private var analysisTask: Task<Void, Error>?
    private var resultsTask: Task<Void, Never>?
    private var transcript = DictationTranscript()
    private var ended = false

    init(recognizer: DictationRecognizer) {
        self.recognizer = recognizer
        analyzer = SpeechAnalyzer(
            modules: [recognizer.module],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering)
        )
        (input, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
    }

    func start(onUpdate: @escaping @MainActor (DictationTranscript) -> Void) async throws {
        let naturalFormat = capture.naturalFormat
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [recognizer.module],
            considering: naturalFormat
        ) else {
            DictationDiagnostics.log.error("The recognizer offered no audio format for \(naturalFormat.description, privacy: .public)")
            throw DictationFailure.startFailed
        }

        let results = recognizer.results()
        resultsTask = Task { @MainActor [weak self] in
            do {
                for try await result in results {
                    guard let self, !Task.isCancelled else { return }
                    self.transcript.apply(result.text, isFinal: result.isFinal)
                    onUpdate(self.transcript)
                }
            } catch {
                DictationDiagnostics.log.error("Dictation results ended: \(String(describing: type(of: error)), privacy: .public)")
            }
        }

        // Audio captured while the model loads waits in the stream.
        let continuation = inputContinuation
        try capture.start(convertingTo: format) { continuation.yield($0) }

        let analyzer = analyzer
        let input = input
        analysisTask = Task {
            try await analyzer.prepareToAnalyze(in: format)
            try await analyzer.start(inputSequence: input)
        }
    }

    func finish() async -> String {
        guard !ended else { return transcript.text }
        ended = true
        capture.stop()
        inputContinuation.finish()
        let analyzer = analyzer
        let analysisTask = analysisTask
        let resultsTask = resultsTask
        let settled = await Self.complete(within: Self.finishTimeoutNanoseconds) {
            do {
                try await analysisTask?.value
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                await analyzer.cancelAndFinishNow()
            }
            await resultsTask?.value
        }
        if !settled {
            await analyzer.cancelAndFinishNow()
            resultsTask?.cancel()
        }
        return transcript.text
    }

    func cancel() async {
        guard !ended else { return }
        ended = true
        capture.stop()
        inputContinuation.finish()
        analysisTask?.cancel()
        resultsTask?.cancel()
        await analyzer.cancelAndFinishNow()
    }

    /// Runs `work` and reports whether it finished in time, without waiting
    /// for a recognizer that ignores cancellation.
    private static func complete(
        within nanoseconds: UInt64,
        _ work: @escaping @Sendable () async -> Void
    ) async -> Bool {
        let gate = DictationResumeGate()
        return await withCheckedContinuation { continuation in
            gate.install(continuation)
            Task {
                await work()
                gate.resume(true)
            }
            Task {
                try? await Task.sleep(nanoseconds: nanoseconds)
                gate.resume(false)
            }
        }
    }
}

/// Resumes a continuation once, from whichever side finishes first.
nonisolated private final class DictationResumeGate: Sendable {
    private let continuation = Mutex<CheckedContinuation<Bool, Never>?>(nil)

    func install(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation.withLock { $0 = continuation }
    }

    func resume(_ value: Bool) {
        let continuation = self.continuation.withLock { stored in
            defer { stored = nil }
            return stored
        }
        continuation?.resume(returning: value)
    }
}

/// Taps the microphone and converts its buffers to the recognizer's format.
/// The engine is driven from the MainActor; the tap block, built in a
/// nonisolated function, runs on the audio thread.
@available(iOS 26.0, *)
@MainActor
private final class DictationAudioCapture {
    private let engine = AVAudioEngine()
    private var running = false

    var naturalFormat: AVAudioFormat {
        engine.inputNode.outputFormat(forBus: 0)
    }

    func start(
        convertingTo format: AVAudioFormat,
        deliver: @escaping @Sendable (AnalyzerInput) -> Void
    ) throws {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            DictationDiagnostics.log.error("No microphone input (\(inputFormat.sampleRate, privacy: .public) Hz)")
            throw DictationFailure.startFailed
        }
        guard let converter = DictationBufferConverter(from: inputFormat, to: format) else {
            DictationDiagnostics.log.error("Can't convert microphone audio to \(format.description, privacy: .public)")
            throw DictationFailure.startFailed
        }
        inputNode.installTap(
            onBus: 0,
            bufferSize: 2_048,
            format: inputFormat,
            block: Self.tap(converter: converter, deliver: deliver)
        )
        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            DictationDiagnostics.log.error("The audio engine didn't start: \(String(describing: error), privacy: .public)")
            throw DictationFailure.startFailed
        }
        running = true
    }

    func stop() {
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    nonisolated private static func tap(
        converter: DictationBufferConverter,
        deliver: @escaping @Sendable (AnalyzerInput) -> Void
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            guard let converted = converter.convert(buffer) else { return }
            deliver(AnalyzerInput(buffer: converted))
        }
    }
}

/// Owned by one tap block, so only the audio tap's serial thread uses it.
nonisolated private final class DictationBufferConverter {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat

    init?(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { return nil }
        // Priming adds leading silence and drifts the timestamps the
        // recognizer relies on.
        converter.primeMethod = .none
        self.converter = converter
        self.outputFormat = outputFormat
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard buffer.frameLength > 0,
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)
        else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}
