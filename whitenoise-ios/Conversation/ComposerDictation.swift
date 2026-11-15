import AVFoundation
import Foundation
import Observation
import SwiftUI

/// Hold-to-dictate for the composer. iOS transcribes the speech on device;
/// the audio is never written to disk or sent anywhere.
nonisolated enum ComposerDictationSupport {
    /// `SpeechAnalyzer` arrived in iOS 26. Older systems don't offer the
    /// feature at all rather than falling back to the older recognizer.
    static var isSupportedOS: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    /// One hold transcribes at most this much speech, then finishes.
    static let maximumDurationNanoseconds: UInt64 = 120_000_000_000

    /// Releasing a hold sends, so sliding this far left discards instead.
    static let cancelTranslationX: CGFloat = -90

    static func shouldCancel(translation: CGSize) -> Bool {
        translation.width <= cancelTranslationX
    }
}

/// The Settings switch for hold-to-dictate, on unless the person turned it off.
@MainActor
@Observable
final class ComposerDictationPreferenceStore {
    static let shared = ComposerDictationPreferenceStore()
    static let storageKey = "composer.holdToDictate"

    private let defaults: UserDefaults
    private(set) var isEnabled: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isEnabled = defaults.object(forKey: Self.storageKey) as? Bool ?? true
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        HostSettingsSaveTiming.measure { defaults.set(enabled, forKey: Self.storageKey) }
    }
}

/// Where the speech model for the person's language stands.
nonisolated enum DictationModelStatus: Equatable {
    case unknown
    case checking
    case ready
    case notInstalled
    case downloading
    case unsupportedLanguage
    case failed

    /// After a download attempt the inventory is the truth: only a model that
    /// is still missing failed. One iOS is still fetching, or that just
    /// became ready, did not.
    static func afterInstallAttempt(_ refreshed: DictationModelStatus) -> DictationModelStatus {
        refreshed == .notInstalled ? .failed : refreshed
    }
}

/// Joins dictated text onto the existing draft.
nonisolated enum DictationTextMerge {
    static func merged(draft: String, transcript: String) -> String {
        let dictated = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dictated.isEmpty else { return draft }
        guard let last = draft.last else { return dictated }
        if last.isWhitespace || !needsSeparator(after: last, before: dictated) {
            return draft + dictated
        }
        return draft + " " + dictated
    }

    /// Scripts written without spaces (Chinese, Japanese) join directly.
    private static func needsSeparator(after last: Character, before dictated: String) -> Bool {
        guard let first = dictated.first else { return false }
        return !(isUnspacedScript(last) && isUnspacedScript(first))
    }

    private static func isUnspacedScript(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF:
                true
            default:
                false
            }
        }
    }
}

nonisolated enum DictationInterruptionPolicy {
    /// An interruption that begins (a call, another app's recording) takes
    /// the microphone, so dictation stops rather than waiting on dead input.
    static func cancelsDictation(_ userInfo: [AnyHashable: Any]?) -> Bool {
        guard let raw = userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return false }
        return type == .began
    }
}

/// Which languages to try, most likely first.
nonisolated enum DictationLocalePolicy {
    /// The keyboard the person last typed with in this field is the best
    /// guess at the language they speak; then their enabled keyboards, then
    /// their preferred languages.
    static func candidateIdentifiers(
        lastKeyboardLanguage: String?,
        activeKeyboardLanguages: [String],
        preferredLanguages: [String]
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for identifier in [lastKeyboardLanguage].compactMap(\.self) + activeKeyboardLanguages + preferredLanguages {
            guard isSpokenLanguage(identifier) else { continue }
            let key = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(identifier)
        }
        return result
    }

    /// Emoji and dictation input modes report pseudo-languages.
    private static func isSpokenLanguage(_ identifier: String) -> Bool {
        let trimmed = identifier.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return !["emoji", "dictation", "mul", "und"].contains(trimmed.lowercased())
    }
}

/// Text recognized so far: settled text, then the recognizer's current guess
/// for the words still being spoken.
nonisolated struct DictationTranscript: Equatable, Sendable {
    var finalized = ""
    var volatile = ""

    var text: String { finalized + volatile }
    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// A final result settles its audio range, replacing the guess for it.
    mutating func apply(_ text: String, isFinal: Bool) {
        if isFinal {
            finalized += text
            volatile = ""
        } else {
            volatile = text
        }
    }
}

nonisolated enum DictationFailure: LocalizedError, Equatable {
    case permissionDenied
    case unsupportedLanguage
    /// iOS is downloading the speech model; the person tries again after.
    case modelDownloading
    case startFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            L10n.string("Microphone access is needed to dictate messages.")
        case .unsupportedLanguage:
            L10n.string("Dictation isn't available for your language.")
        case .modelDownloading:
            L10n.string("iOS is downloading the speech model for your language. Try again in a moment.")
        case .startFailed:
            L10n.string("Dictation couldn't start.")
        }
    }
}

/// What a finished dictation recognized.
nonisolated struct DictationResult: Equatable, Sendable {
    var text: String
    /// False when recognition failed or timed out before settling, so the
    /// text may be missing words and must not be sent unseen.
    var isComplete: Bool
}

/// A transcription in progress.
nonisolated struct DictationSession {
    /// Stops listening and returns everything recognized.
    var finish: @MainActor () async -> DictationResult
    /// Stops listening and discards the text.
    var cancel: @MainActor () async -> Void
}

/// The speech recognizer behind dictation. Production uses `SpeechAnalyzer`.
nonisolated struct DictationEngine {
    /// Starts listening. `onUpdate` receives the transcript as it changes.
    var start: @MainActor (
        _ localeIdentifiers: [String],
        _ onUpdate: @escaping @MainActor (DictationTranscript) -> Void
    ) async throws -> DictationSession

    static var live: DictationEngine {
        if #available(iOS 26.0, *) {
            return DictationEngine(start: SpeechAnalyzerDictation.start)
        }
        return DictationEngine { _, _ in throw DictationFailure.startFailed }
    }
}

/// Drives one hold of the message field: starts listening, follows the
/// drag that locks hands-free dictation, and hands back the text.
@MainActor
@Observable
final class ComposerDictationController {
    enum State: Equatable {
        case idle
        /// Waiting for permission and the recognizer to start.
        case starting(locked: Bool)
        case listening(locked: Bool)
        /// Released; the recognizer is settling the last words.
        case finishing

        var isActive: Bool { self != .idle }

        var isLocked: Bool {
            switch self {
            case .starting(let locked), .listening(let locked): locked
            case .idle, .finishing: false
            }
        }
    }

    private(set) var state: State = .idle
    private(set) var transcript = DictationTranscript()

    @ObservationIgnored private let engine: DictationEngine
    @ObservationIgnored private let maximumDurationNanoseconds: UInt64
    @ObservationIgnored private var session: DictationSession?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var limitTask: Task<Void, Never>?
    @ObservationIgnored private var releasedWhileStarting = false
    @ObservationIgnored private var onFinish: ((DictationResult) -> Void)?
    @ObservationIgnored private var generation = 0

    var isActive: Bool { state.isActive }
    var isLocked: Bool { state.isLocked }

    init(
        engine: DictationEngine = .live,
        maximumDurationNanoseconds: UInt64 = ComposerDictationSupport.maximumDurationNanoseconds
    ) {
        self.engine = engine
        self.maximumDurationNanoseconds = maximumDurationNanoseconds
    }

    isolated deinit {
        startTask?.cancel()
        limitTask?.cancel()
        if let session {
            Task { await session.cancel() }
        }
    }

    /// Starts listening. `onFinish` receives the text once the hold ends
    /// (or the locked dictation is stopped); `onError` reports a start failure.
    func begin(
        localeIdentifiers: [String],
        locked: Bool = false,
        onFinish: @escaping (DictationResult) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        guard state == .idle else { return }
        generation &+= 1
        let generation = generation
        state = .starting(locked: locked)
        transcript = DictationTranscript()
        releasedWhileStarting = false
        self.onFinish = onFinish
        startTask = Task { @MainActor [weak self, engine] in
            do {
                let session = try await engine.start(localeIdentifiers) { [weak self] update in
                    guard let self, self.generation == generation, self.state.isActive else { return }
                    self.transcript = update
                }
                guard let self, self.generation == generation, case .starting(let locked) = self.state else {
                    await session.cancel()
                    return
                }
                self.session = session
                self.startTask = nil
                self.state = .listening(locked: locked)
                Haptics.tap()
                self.armDurationLimit(generation: generation)
                if self.releasedWhileStarting, !locked {
                    self.finish()
                }
            } catch {
                guard let self, self.generation == generation else { return }
                self.reset()
                if !(error is CancellationError) {
                    onError(error)
                }
            }
        }
    }

    /// Dragging up far enough locks dictation so the finger can lift;
    /// dragging left far enough discards it.
    func updateDrag(_ translation: CGSize) {
        if ComposerDictationSupport.shouldCancel(translation: translation), !state.isLocked,
           state != .finishing {
            cancel()
            return
        }
        guard VoiceRecordingGesturePolicy.shouldLock(translation: translation) else { return }
        switch state {
        case .starting(false):
            state = .starting(locked: true)
        case .listening(false):
            state = .listening(locked: true)
        default:
            return
        }
        Haptics.tap()
    }

    /// The finger lifted. Unlocked dictation finishes and hands back its text.
    func endPress() {
        switch state {
        case .starting(false):
            releasedWhileStarting = true
        case .listening(false):
            finish()
        case .idle, .starting(true), .listening(true), .finishing:
            return
        }
    }

    /// Stops locked dictation and hands back its text.
    func stopLocked() {
        guard case .listening(true) = state else { return }
        finish()
    }

    func cancel() {
        guard state.isActive else { return }
        let session = session
        reset()
        Haptics.tap()
        if let session {
            Task { await session.cancel() }
        }
    }

    private func finish() {
        guard let session else { return }
        self.session = nil
        limitTask?.cancel()
        limitTask = nil
        state = .finishing
        let generation = generation
        Task { @MainActor [weak self] in
            let result = await session.finish()
            guard let self, self.generation == generation else { return }
            let onFinish = self.onFinish
            self.reset()
            Haptics.tap()
            onFinish?(result)
        }
    }

    private func armDurationLimit(generation: Int) {
        limitTask?.cancel()
        limitTask = Task { @MainActor [weak self, maximumDurationNanoseconds] in
            do {
                try await Task.sleep(nanoseconds: maximumDurationNanoseconds)
            } catch {
                return
            }
            guard let self, self.generation == generation, case .listening = self.state else { return }
            self.finish()
        }
    }

    private func reset() {
        generation &+= 1
        startTask?.cancel()
        startTask = nil
        limitTask?.cancel()
        limitTask = nil
        session = nil
        onFinish = nil
        releasedWhileStarting = false
        state = .idle
        transcript = DictationTranscript()
    }
}
