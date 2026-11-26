import AVFoundation
import Combine
import SwiftUI

struct VoiceRecordingResult: Sendable {
    let url: URL
    let fileName: String
    let durationSeconds: Double
    let waveformSamples: [CGFloat]
}

/// The hold that records a voice message or dictates: slide up to lock it
/// hands-free, slide left to discard it.
nonisolated enum HoldGesturePolicy {
    static let lockTranslationY: CGFloat = -78
    static let cancelTranslationX: CGFloat = -90
    static let holdDelayNanoseconds: UInt64 = 260_000_000

    static func shouldLock(translation: CGSize) -> Bool {
        translation.height <= lockTranslationY
    }

    static func shouldCancel(translation: CGSize) -> Bool {
        translation.width <= cancelTranslationX
    }

    /// How far toward locking the finger has slid, from 0 to 1.
    static func lockProgress(_ translation: CGSize) -> CGFloat {
        min(1, max(0, translation.height / lockTranslationY))
    }

    /// How far toward cancelling the finger has slid, from 0 to 1.
    static func cancelProgress(_ translation: CGSize) -> CGFloat {
        min(1, max(0, translation.width / cancelTranslationX))
    }

    /// The bubble under the thumb follows the finger, but only left toward
    /// cancel and up toward the lock, and no further than either.
    static func thumbOffset(_ translation: CGSize) -> CGSize {
        CGSize(
            width: min(0, max(cancelTranslationX, translation.width)),
            height: min(0, max(lockTranslationY, translation.height))
        )
    }
}

nonisolated enum VoiceRecordingFileProtection {
    static let activeRecording = FileProtectionType.completeUnlessOpen
    static let completedRecording = FileProtectionType.complete
}

nonisolated enum VoiceRecordingLimit {
    static let maxDurationSeconds: TimeInterval = 600
}

nonisolated struct VoiceRecordingWaveformAccumulator: Sendable {
    private var samples: [CGFloat] = []

    mutating func append(_ sample: CGFloat) {
        samples.append(max(0.05, min(1, sample)))
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }

    func persistedSamples(bucketCount: Int = MediaWaveformAnalyzer.sampleCount) -> [CGFloat] {
        guard bucketCount > 0 else { return [] }
        guard samples.count > bucketCount else {
            return MediaWaveformAnalyzer.normalized(samples)
        }
        var peaks = [CGFloat](repeating: 0.08, count: bucketCount)
        for (index, sample) in samples.enumerated() {
            let bucket = min(bucketCount - 1, index * bucketCount / samples.count)
            peaks[bucket] = max(peaks[bucket], sample)
        }
        return MediaWaveformAnalyzer.normalized(peaks)
    }
}

@MainActor
final class VoiceMessageRecorder: NSObject, ObservableObject {
    enum RecordingState: Equatable {
        case idle
        case pressing
        case recording(locked: Bool)

        var isActive: Bool {
            switch self {
            case .idle: false
            case .pressing, .recording: true
            }
        }

        var isLocked: Bool {
            guard case .recording(let locked) = self else { return false }
            return locked
        }

        var hasStartedRecording: Bool {
            guard case .recording = self else { return false }
            return true
        }
    }

    enum Failure: LocalizedError {
        case permissionDenied
        case startFailed

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return L10n.string("Microphone access is needed to record voice messages.")
            case .startFailed:
                return L10n.string("Voice recording could not start.")
            }
        }
    }

    @Published private(set) var state: RecordingState = .idle
    @Published private(set) var waveformSamples: [CGFloat] = []
    @Published private(set) var durationSeconds: Double = 0

    private let audioSession: VoiceAudioSessionConfiguring
    private let microphone: VoiceRecordingMicrophone
    private var take: VoiceRecordingTake?
    private var recordingURL: URL?
    private var audioSessionLease: VoiceAudioSession.Lease?
    private var currentDragTranslation: CGSize = .zero
    private var holdTask: Task<Void, Never>?
    private var onLimitReached: ((VoiceRecordingResult) -> Void)?
    private var meterTask: Task<Void, Never>?
    private var waveformAccumulator = VoiceRecordingWaveformAccumulator()

    var isActive: Bool { state.isActive }
    var isLocked: Bool { state.isLocked }
    var hasStartedRecording: Bool { state.hasStartedRecording }

    init(
        audioSession: VoiceAudioSessionConfiguring = AVAudioSession.sharedInstance(),
        microphone: VoiceRecordingMicrophone = .live
    ) {
        self.audioSession = audioSession
        self.microphone = microphone
        super.init()
    }

    isolated deinit {
        if state.isActive || take != nil || recordingURL != nil || holdTask != nil || meterTask != nil {
            reset(deleteFile: true)
        }
    }

    func beginPress(
        onError: @escaping (Error) -> Void,
        onLimitReached: @escaping (VoiceRecordingResult) -> Void = { _ in }
    ) {
        guard state == .idle else { return }
        state = .pressing
        self.onLimitReached = onLimitReached
        currentDragTranslation = .zero
        durationSeconds = 0
        waveformSamples = []
        waveformAccumulator.reset()
        holdTask?.cancel()
        holdTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: HoldGesturePolicy.holdDelayNanoseconds)
            } catch {
                return
            }
            guard let self, !Task.isCancelled, self.state == .pressing else { return }
            do {
                try await self.startRecording()
            } catch is CancellationError {
                self.reset(deleteFile: true)
            } catch {
                self.reset(deleteFile: true)
                onError(error)
            }
        }
    }

    func updateDrag(_ translation: CGSize) {
        currentDragTranslation = translation
        if HoldGesturePolicy.shouldCancel(translation: translation), state.isActive, !state.isLocked {
            cancel()
            return
        }
        guard HoldGesturePolicy.shouldLock(translation: translation),
              case .recording(false) = state
        else { return }
        Haptics.tap()
        state = .recording(locked: true)
    }

    func endPress() -> VoiceRecordingResult? {
        holdTask?.cancel()
        holdTask = nil
        switch state {
        case .idle:
            return nil
        case .pressing:
            reset(deleteFile: true)
            return nil
        case .recording(let locked):
            guard !locked else { return nil }
            return finishRecording()
        }
    }

    func stopLockedRecording() -> VoiceRecordingResult? {
        guard state.isLocked else { return nil }
        return finishRecording()
    }

    func cancel() {
        Haptics.tap()
        reset(deleteFile: true)
    }

    func finishIfActive() -> VoiceRecordingResult? {
        holdTask?.cancel()
        holdTask = nil
        switch state {
        case .idle:
            return nil
        case .pressing:
            reset(deleteFile: true)
            return nil
        case .recording:
            return finishRecording()
        }
    }

    func cancelIfActive() {
        guard state.isActive else { return }
        cancel()
    }

    private func startRecording() async throws {
        let hasPermission = await microphone.requestPermission()
        try Task.checkCancellation()
        guard hasPermission else {
            throw Failure.permissionDenied
        }

        do {
            audioSessionLease = try VoiceAudioSession.configureForRecording(audioSession)
        } catch {
            throw Failure.startFailed
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhiteNoiseVoiceRecordings", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: VoiceRecordingFileProtection.activeRecording]
            )
        } catch {
            throw Failure.startFailed
        }

        let fileName = "voice-\(Int(Date().timeIntervalSince1970)).m4a"
        let url = directory.appendingPathComponent(fileName)
        do {
            let take = try microphone.startRecording(url)
            // A release that ran between the pre-flight checkpoint and here
            // already cancelled this task; committing anyway leaves a live
            // microphone behind a banner the user believes they dismissed.
            if Task.isCancelled {
                take.stop()
                try? FileManager.default.removeItem(at: url)
                throw CancellationError()
            }
            self.take = take
            self.recordingURL = url
            state = .recording(locked: HoldGesturePolicy.shouldLock(translation: currentDragTranslation))
            Haptics.tap()
            startMetering()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.startFailed
        }
    }

    private func startMetering() {
        meterTask?.cancel()
        meterTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 70_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self, let take = self.take else { return }
                let level = take.meter()
                self.durationSeconds = min(level.seconds, VoiceRecordingLimit.maxDurationSeconds)
                let power = level.averagePower
                let normalized = max(0.05, min(1, CGFloat(pow(10, power / 36))))
                self.waveformAccumulator.append(normalized)
                self.waveformSamples.append(normalized)
                if self.waveformSamples.count > MediaWaveformAnalyzer.sampleCount {
                    self.waveformSamples.removeFirst(self.waveformSamples.count - MediaWaveformAnalyzer.sampleCount)
                }
                if level.seconds >= VoiceRecordingLimit.maxDurationSeconds {
                    self.finishAtLimit()
                    return
                }
            }
        }
    }

    private func finishAtLimit() {
        meterTask = nil
        let handler = onLimitReached
        guard let result = finishRecording() else { return }
        Haptics.tap()
        handler?(result)
    }

    private func finishRecording() -> VoiceRecordingResult? {
        guard let url = recordingURL else {
            reset(deleteFile: true)
            return nil
        }
        let duration = min(
            max(durationSeconds, take?.currentTime() ?? 0),
            VoiceRecordingLimit.maxDurationSeconds
        )
        take?.stop()
        take = nil
        try? FileManager.default.setAttributes(
            [.protectionKey: VoiceRecordingFileProtection.completedRecording],
            ofItemAtPath: url.path
        )
        let result = VoiceRecordingResult(
            url: url,
            fileName: url.lastPathComponent,
            durationSeconds: duration,
            waveformSamples: waveformAccumulator.persistedSamples()
        )
        reset(deleteFile: false)
        return result
    }

    private func reset(deleteFile: Bool) {
        holdTask?.cancel()
        holdTask = nil
        onLimitReached = nil
        meterTask?.cancel()
        meterTask = nil
        take?.stop()
        take = nil
        let url = recordingURL
        recordingURL = nil
        currentDragTranslation = .zero
        state = .idle
        durationSeconds = 0
        waveformSamples = []
        waveformAccumulator.reset()
        if deleteFile, let url {
            try? FileManager.default.removeItem(at: url)
        }
        releaseAudioSession()
    }

    private func releaseAudioSession() {
        VoiceAudioSession.deactivate(audioSessionLease)
        audioSessionLease = nil
    }
}

nonisolated struct AudioWaveformBar: Equatable, Sendable {
    let amplitude: CGFloat

    static func visible(_ amplitude: CGFloat) -> AudioWaveformBar {
        AudioWaveformBar(amplitude: min(1, max(0.05, amplitude)))
    }
}

nonisolated enum AudioWaveformPresentation {
    static let amplitudeCurveExponent: Double = 0.45

    static func bars(
        for samples: [CGFloat],
        count: Int = MediaWaveformAnalyzer.sampleCount
    ) -> [AudioWaveformBar] {
        guard count > 0 else { return [] }
        return MediaWaveformAnalyzer.normalized(samples, count: count)
            .map(displayAmplitude)
            .map(AudioWaveformBar.visible)
    }

    private static func displayAmplitude(_ sample: CGFloat) -> CGFloat {
        let bounded = min(1, max(0.05, sample))
        return min(1, max(0.05, CGFloat(pow(Double(bounded), amplitudeCurveExponent))))
    }
}

struct AudioWaveformView: View {
    let samples: [CGFloat]
    let progress: CGFloat
    let barColor: Color
    let playedColor: Color
    var fitsAvailableWidth = false

    var body: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 2
            let count = fitsAvailableWidth ? min(MediaWaveformAnalyzer.sampleCount, max(1, Int((geometry.size.width + spacing) / 4))) : MediaWaveformAnalyzer.sampleCount
            let bars = AudioWaveformPresentation.bars(for: samples, count: count)
            let barCount = max(1, bars.count)
            let availableWidth = geometry.size.width - spacing * CGFloat(max(0, barCount - 1))
            let barWidth = max(2, availableWidth / CGFloat(barCount))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(bars.enumerated()), id: \.offset) { index, bar in
                    let played = CGFloat(index) / CGFloat(max(1, bars.count - 1)) <= progress
                    Capsule()
                        .fill(played ? playedColor : barColor)
                        .frame(
                            width: barWidth,
                            height: max(4, geometry.size.height * min(1, max(0.08, bar.amplitude)))
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .clipped()
        .accessibilityHidden(true)
    }
}
