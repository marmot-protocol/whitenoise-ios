import AVFoundation
import Foundation
import Testing
import UIKit
@testable import whitenoise_ios

struct DictationTextMergeTests {
    @Test func dictationIntoAnEmptyDraftIsTheTrimmedTranscript() {
        #expect(DictationTextMerge.merged(draft: "", transcript: "  Hello there. ") == "Hello there.")
    }

    @Test func dictationAfterAWordIsSeparatedBySpace() {
        #expect(DictationTextMerge.merged(draft: "Sounds good.", transcript: "See you soon") == "Sounds good. See you soon")
    }

    @Test func dictationAfterWhitespaceAddsNoSecondSpace() {
        #expect(DictationTextMerge.merged(draft: "Hi ", transcript: "there") == "Hi there")
        #expect(DictationTextMerge.merged(draft: "Line\n", transcript: "next") == "Line\nnext")
    }

    @Test func silenceLeavesTheDraftUntouched() {
        #expect(DictationTextMerge.merged(draft: "Draft", transcript: " \n") == "Draft")
    }

    @Test func unspacedScriptsJoinWithoutASpace() {
        #expect(DictationTextMerge.merged(draft: "你好", transcript: "世界") == "你好世界")
        #expect(DictationTextMerge.merged(draft: "你好", transcript: "OK") == "你好 OK")
    }
}

struct DictationLocalePolicyTests {
    @Test func theLastKeyboardComesFirstThenKeyboardsThenPreferredLanguages() {
        let candidates = DictationLocalePolicy.candidateIdentifiers(
            lastKeyboardLanguage: "de-DE",
            activeKeyboardLanguages: ["en-US", "de-DE"],
            preferredLanguages: ["fr-FR", "en-US"]
        )
        #expect(candidates == ["de-DE", "en-US", "fr-FR"])
    }

    @Test func pseudoLanguagesAndSpellingVariantsAreSkipped() {
        let candidates = DictationLocalePolicy.candidateIdentifiers(
            lastKeyboardLanguage: "emoji",
            activeKeyboardLanguages: ["dictation", "en_US", ""],
            preferredLanguages: ["en-us", "pt-BR"]
        )
        #expect(candidates == ["en_US", "pt-BR"])
    }
}

struct DictationTranscriptTests {
    @Test func finalResultsSettleAndReplaceTheGuess() {
        var transcript = DictationTranscript()
        transcript.apply("Hel", isFinal: false)
        transcript.apply("Hello", isFinal: false)
        #expect(transcript.text == "Hello")

        transcript.apply("Hello world.", isFinal: true)
        transcript.apply(" How", isFinal: false)
        #expect(transcript.finalized == "Hello world.")
        #expect(transcript.text == "Hello world. How")

        transcript.apply(" How are you?", isFinal: true)
        #expect(transcript.volatile.isEmpty)
        #expect(transcript.text == "Hello world. How are you?")
    }

    @Test func thePreviewSplitsSettledTextFromTheGuessAsItWillBeInserted() {
        let transcript = DictationTranscript(finalized: "See you", volatile: " soon")
        let preview = ComposerDictationPresentation.preview(draft: "OK.", transcript: transcript)
        #expect(preview.settled == "OK. See you")
        #expect(preview.pending == " soon")
        #expect(preview.settled + preview.pending == DictationTextMerge.merged(draft: "OK.", transcript: transcript.text))
    }
}

@MainActor
struct ComposerDictationPreferenceStoreTests {
    @Test func dictationIsOnUntilThePersonTurnsItOff() throws {
        let suiteName = "ComposerDictationPreferenceStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(ComposerDictationPreferenceStore(defaults: defaults).isEnabled)

        ComposerDictationPreferenceStore(defaults: defaults).setEnabled(false)
        #expect(!ComposerDictationPreferenceStore(defaults: defaults).isEnabled)
    }
}

struct ComposerDictationPresentationTests {
    @Test func theRestingFieldExplainsBothGesturesOnlyWhereDictationIsOffered() {
        let message = ComposerDictationPresentation.placeholder(offersDictation: false, isTyping: false)
        let resting = ComposerDictationPresentation.placeholder(offersDictation: true, isTyping: false)
        #expect(resting != message)
        #expect(ComposerDictationPresentation.placeholder(offersDictation: true, isTyping: true) == message)
    }

    @Test func dictationSendsExceptWhileEditingASentMessage() {
        #expect(ComposerDictationPresentation.sendsOnFinish(isEditing: false))
        #expect(!ComposerDictationPresentation.sendsOnFinish(isEditing: true))
    }

    @Test func noNewHoldStartsWhileASendOwnsTheDraft() {
        #expect(!ComposerDictationPresentation.admitsHold(isSending: true, isDictating: false))
        #expect(ComposerDictationPresentation.admitsHold(isSending: true, isDictating: true))
        #expect(ComposerDictationPresentation.admitsHold(isSending: false, isDictating: false))
    }

    @Test func onlyAModelStillMissingAfterADownloadFailed() {
        #expect(DictationModelStatus.afterInstallAttempt(.notInstalled) == .failed)
        #expect(DictationModelStatus.afterInstallAttempt(.downloading) == .downloading)
        #expect(DictationModelStatus.afterInstallAttempt(.ready) == .ready)
        #expect(DictationModelStatus.afterInstallAttempt(.unsupportedLanguage) == .unsupportedLanguage)
    }

    @Test func textRecognitionDidNotSettleIsLeftForReviewInsteadOfSent() {
        #expect(!ComposerDictationPresentation.sendsOnFinish(isEditing: false, isComplete: false))
    }
}

struct DictationGestureAndInterruptionTests {
    @Test func onlyALiftedFingerFinishesAHold() {
        #expect(ComposerDictationGesturePolicy.event(for: .ended) == .ended)
        #expect(ComposerDictationGesturePolicy.event(for: .cancelled) == .cancelled)
        #expect(ComposerDictationGesturePolicy.event(for: .failed) == nil)
        #expect(ComposerDictationGesturePolicy.event(for: .possible) == nil)
    }

    @Test func aHoldDictatesOnlyOnTheRestingField() {
        #expect(ComposerDictationGesturePolicy.admitsHold(isAvailable: true, isEditing: false))
        #expect(!ComposerDictationGesturePolicy.admitsHold(isAvailable: true, isEditing: true))
        #expect(!ComposerDictationGesturePolicy.admitsHold(isAvailable: false, isEditing: false))
    }

    @Test func onlyABeginningInterruptionStopsDictation() {
        let began = [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        let ended = [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue]
        #expect(DictationInterruptionPolicy.cancelsDictation(began))
        #expect(!DictationInterruptionPolicy.cancelsDictation(ended))
        #expect(!DictationInterruptionPolicy.cancelsDictation(nil))
    }
}

@MainActor
struct ComposerDictationControllerTests {
    @Test func releasingAHoldInsertsTheTranscript() async throws {
        let engine = DictationEngineDouble(finalText: "Hello there.")
        let controller = ComposerDictationController(engine: engine.engine)
        let inserted = Inserted()

        controller.begin(localeIdentifiers: ["en-US"], onFinish: inserted.record, onError: { Issue.record($0) })
        try await eventually { controller.state == .listening(locked: false) }
        engine.emit(DictationTranscript(finalized: "", volatile: "Hello"))
        #expect(controller.transcript.text == "Hello")

        controller.endPress()
        try await eventually { inserted.texts == ["Hello there."] }
        #expect(controller.state == .idle)
        #expect(engine.finishes == 1)
        #expect(engine.requestedLocales == [["en-US"]])
    }

    @Test func aReleaseBeforeListeningStartsFinishesOnceItStarts() async throws {
        let engine = DictationEngineDouble(finalText: "Quick.")
        let checkpoint = AsyncTestCheckpoint()
        engine.beforeStart = { await checkpoint.pause() }
        let controller = ComposerDictationController(engine: engine.engine)
        let inserted = Inserted()

        controller.begin(localeIdentifiers: ["en-US"], onFinish: inserted.record, onError: { Issue.record($0) })
        await checkpoint.waitUntilPaused()
        controller.endPress()
        #expect(controller.state == .starting(locked: false))

        await checkpoint.release()
        try await eventually { inserted.texts == ["Quick."] }
        #expect(controller.state == .idle)
    }

    @Test func cancellingWhileStartingStopsTheSessionAndInsertsNothing() async throws {
        let engine = DictationEngineDouble(finalText: "Never.")
        let checkpoint = AsyncTestCheckpoint()
        engine.beforeStart = { await checkpoint.pause() }
        let controller = ComposerDictationController(engine: engine.engine)
        let inserted = Inserted()

        controller.begin(localeIdentifiers: ["en-US"], onFinish: inserted.record, onError: { Issue.record($0) })
        await checkpoint.waitUntilPaused()
        controller.cancel()
        #expect(controller.state == .idle)

        await checkpoint.release()
        try await eventually { engine.cancels == 1 }
        #expect(engine.finishes == 0)
        #expect(inserted.texts.isEmpty)
        #expect(controller.state == .idle)
    }

    @Test func cancellingWhileTheLastWordsSettleDeliversNothing() async throws {
        let engine = DictationEngineDouble(finalText: "Too late.")
        let checkpoint = AsyncTestCheckpoint()
        engine.beforeFinish = { await checkpoint.pause() }
        let controller = ComposerDictationController(engine: engine.engine)
        let inserted = Inserted()

        controller.begin(localeIdentifiers: ["en-US"], onFinish: inserted.record, onError: { Issue.record($0) })
        try await eventually { controller.state == .listening(locked: false) }
        controller.endPress()
        await checkpoint.waitUntilPaused()
        #expect(controller.state == .finishing)

        controller.cancel()
        #expect(controller.state == .idle)
        await checkpoint.release()
        try await eventually { engine.finishes == 1 }
        await Task.yield()
        #expect(inserted.results.isEmpty)
    }

    @Test func slidingUpLocksSoReleasingKeepsListeningUntilStopped() async throws {
        let engine = DictationEngineDouble(finalText: "Hands free.")
        let controller = ComposerDictationController(engine: engine.engine)
        let inserted = Inserted()

        controller.begin(localeIdentifiers: ["en-US"], onFinish: inserted.record, onError: { Issue.record($0) })
        try await eventually { controller.state == .listening(locked: false) }
        controller.updateDrag(CGSize(width: 0, height: VoiceRecordingGesturePolicy.lockTranslationY - 1))
        controller.endPress()
        #expect(controller.isLocked)
        #expect(engine.finishes == 0)

        controller.stopLocked()
        try await eventually { inserted.texts == ["Hands free."] }
    }

    @Test func slidingLeftDiscardsTheHoldSoReleasingSendsNothing() async throws {
        let engine = DictationEngineDouble(finalText: "Oops.")
        let controller = ComposerDictationController(engine: engine.engine)
        let inserted = Inserted()

        controller.begin(localeIdentifiers: ["en-US"], onFinish: inserted.record, onError: { Issue.record($0) })
        try await eventually { controller.state == .listening(locked: false) }
        controller.updateDrag(CGSize(width: ComposerDictationSupport.cancelTranslationX - 1, height: 0))
        controller.endPress()

        #expect(controller.state == .idle)
        try await eventually { engine.cancels == 1 }
        #expect(engine.finishes == 0)
        #expect(inserted.texts.isEmpty)
    }

    @Test func slidingLeftAfterLockingKeepsListening() async throws {
        let engine = DictationEngineDouble(finalText: "Kept.")
        let controller = ComposerDictationController(engine: engine.engine)

        controller.begin(localeIdentifiers: ["en-US"], locked: true, onFinish: { _ in }, onError: { Issue.record($0) })
        try await eventually { controller.state == .listening(locked: true) }
        controller.updateDrag(CGSize(width: ComposerDictationSupport.cancelTranslationX - 1, height: 0))

        #expect(controller.state == .listening(locked: true))
        #expect(engine.cancels == 0)
    }

    @Test func anUnsettledRecognitionReachesTheComposerAsIncomplete() async throws {
        let engine = DictationEngineDouble(finalText: "Half a")
        engine.finishesComplete = false
        let controller = ComposerDictationController(engine: engine.engine)
        let inserted = Inserted()

        controller.begin(localeIdentifiers: ["en-US"], onFinish: inserted.record, onError: { Issue.record($0) })
        try await eventually { controller.state == .listening(locked: false) }
        controller.endPress()

        try await eventually { inserted.results == [DictationResult(text: "Half a", isComplete: false)] }
    }

    @Test func aStartFailureIsReportedAndLeavesTheComposerIdle() async throws {
        let engine = DictationEngineDouble(finalText: "")
        engine.startError = DictationFailure.unsupportedLanguage
        let controller = ComposerDictationController(engine: engine.engine)
        let errors = ErrorLog()

        controller.begin(localeIdentifiers: ["xx"], onFinish: { _ in Issue.record("inserted text") }, onError: errors.record)
        try await eventually { errors.failures == [.unsupportedLanguage] }
        #expect(controller.state == .idle)
    }

    @Test func dictationStopsItselfAtTheDurationLimit() async throws {
        let engine = DictationEngineDouble(finalText: "Long story.")
        let controller = ComposerDictationController(engine: engine.engine, maximumDurationNanoseconds: 1_000_000)
        let inserted = Inserted()

        controller.begin(localeIdentifiers: ["en-US"], locked: true, onFinish: inserted.record, onError: { Issue.record($0) })
        try await eventually { inserted.texts == ["Long story."] }
        #expect(controller.state == .idle)
    }

    @Test func updatesFromACancelledSessionDoNotReachTheNextOne() async throws {
        let engine = DictationEngineDouble(finalText: "Second.")
        let controller = ComposerDictationController(engine: engine.engine)

        controller.begin(localeIdentifiers: ["en-US"], onFinish: { _ in }, onError: { Issue.record($0) })
        try await eventually { controller.state == .listening(locked: false) }
        let staleUpdate = try #require(engine.latestUpdate)
        controller.cancel()

        controller.begin(localeIdentifiers: ["en-US"], onFinish: { _ in }, onError: { Issue.record($0) })
        try await eventually { controller.state == .listening(locked: false) }
        staleUpdate(DictationTranscript(finalized: "Stale", volatile: ""))
        #expect(controller.transcript.isEmpty)
    }
}

@MainActor
private final class Inserted {
    private(set) var results: [DictationResult] = []
    var texts: [String] { results.map(\.text) }
    func record(_ result: DictationResult) { results.append(result) }
}

@MainActor
private final class ErrorLog {
    private(set) var failures: [DictationFailure] = []
    func record(_ error: Error) {
        guard let failure = error as? DictationFailure else {
            Issue.record(error, "unexpected error")
            return
        }
        failures.append(failure)
    }
}

/// Stands in for `SpeechAnalyzer`: starts at once (or after `beforeStart`),
/// forwards emitted transcripts, and finishes with `finalText`.
@MainActor
private final class DictationEngineDouble {
    let finalText: String
    var finishesComplete = true
    var beforeFinish: (@MainActor () async -> Void)?
    var beforeStart: (@MainActor () async -> Void)?
    var startError: Error?
    private(set) var requestedLocales: [[String]] = []
    private(set) var finishes = 0
    private(set) var cancels = 0
    private(set) var latestUpdate: (@MainActor (DictationTranscript) -> Void)?

    init(finalText: String) {
        self.finalText = finalText
    }

    var engine: DictationEngine {
        DictationEngine { [self] locales, onUpdate in
            requestedLocales.append(locales)
            await beforeStart?()
            if let startError { throw startError }
            latestUpdate = onUpdate
            return DictationSession(
                finish: { [self] in
                    await beforeFinish?()
                    finishes += 1
                    return DictationResult(text: finalText, isComplete: finishesComplete)
                },
                cancel: { [self] in cancels += 1 }
            )
        }
    }

    func emit(_ transcript: DictationTranscript) {
        latestUpdate?(transcript)
    }
}
