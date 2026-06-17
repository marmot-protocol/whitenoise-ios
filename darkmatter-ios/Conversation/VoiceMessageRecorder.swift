import AVFoundation
import Combine
import SwiftUI

struct VoiceRecordingResult: Sendable {
    let url: URL
    let fileName: String
    let durationSeconds: Double
    let waveformSamples: [CGFloat]
}

nonisolated enum VoiceRecordingGesturePolicy {
    static let lockTranslationY: CGFloat = -78
    static let holdDelayNanoseconds: UInt64 = 260_000_000

    static func shouldLock(translation: CGSize) -> Bool {
        translation.height <= lockTranslationY
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

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var audioSessionLease: VoiceAudioSession.Lease?
    private var currentDragTranslation: CGSize = .zero
    private var holdTask: Task<Void, Never>?
    private var meterTask: Task<Void, Never>?

    var isActive: Bool { state.isActive }
    var isLocked: Bool { state.isLocked }

    isolated deinit {
        if state.isActive || recorder != nil || recordingURL != nil || holdTask != nil || meterTask != nil {
            reset(deleteFile: true)
        }
    }

    func beginPress(onError: @escaping (Error) -> Void) {
        guard state == .idle else { return }
        state = .pressing
        currentDragTranslation = .zero
        durationSeconds = 0
        waveformSamples = []
        holdTask?.cancel()
        holdTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: VoiceRecordingGesturePolicy.holdDelayNanoseconds)
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
        guard VoiceRecordingGesturePolicy.shouldLock(translation: translation),
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

    func cancelIfActive() {
        guard state.isActive else { return }
        cancel()
    }

#if DEBUG
    func startMeteringForTesting() {
        startMetering()
    }
#endif

    private func startRecording() async throws {
        let hasPermission = await requestRecordPermission()
        try Task.checkCancellation()
        guard hasPermission else {
            throw Failure.permissionDenied
        }

        do {
            audioSessionLease = try VoiceAudioSession.configureForRecording()
        } catch {
            throw Failure.startFailed
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DarkMatterVoiceRecordings", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
        } catch {
            throw Failure.startFailed
        }

        let fileName = "voice-\(Int(Date().timeIntervalSince1970)).m4a"
        let url = directory.appendingPathComponent(fileName)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]

        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else { throw Failure.startFailed }
            self.recorder = recorder
            self.recordingURL = url
            state = .recording(locked: VoiceRecordingGesturePolicy.shouldLock(translation: currentDragTranslation))
            Haptics.tap()
            startMetering()
        } catch {
            throw Failure.startFailed
        }
    }

    private func requestRecordPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
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
                guard !Task.isCancelled, let self, let recorder = self.recorder else { return }
                recorder.updateMeters()
                self.durationSeconds = recorder.currentTime
                let power = recorder.averagePower(forChannel: 0)
                let normalized = max(0.05, min(1, CGFloat(pow(10, power / 36))))
                self.waveformSamples.append(normalized)
                if self.waveformSamples.count > MediaWaveformAnalyzer.sampleCount {
                    self.waveformSamples.removeFirst(self.waveformSamples.count - MediaWaveformAnalyzer.sampleCount)
                }
            }
        }
    }

    private func finishRecording() -> VoiceRecordingResult? {
        guard let recorder, let url = recordingURL else {
            reset(deleteFile: true)
            return nil
        }
        let duration = max(durationSeconds, recorder.currentTime)
        recorder.stop()
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
        let result = VoiceRecordingResult(
            url: url,
            fileName: url.lastPathComponent,
            durationSeconds: duration,
            waveformSamples: waveformSamples
        )
        reset(deleteFile: false)
        return result
    }

    private func reset(deleteFile: Bool) {
        holdTask?.cancel()
        holdTask = nil
        meterTask?.cancel()
        meterTask = nil
        recorder?.stop()
        recorder = nil
        let url = recordingURL
        recordingURL = nil
        currentDragTranslation = .zero
        state = .idle
        durationSeconds = 0
        waveformSamples = []
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

struct VoiceRecordingBanner: View {
    let samples: [CGFloat]
    let durationSeconds: Double
    let isLocked: Bool
    let onCancel: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if isLocked {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.red)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel recording")
            } else {
                Image(systemName: "lock.open")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
            }

            AudioWaveformView(
                samples: samples,
                progress: 0,
                barColor: Color.accentColor.opacity(0.72),
                playedColor: Color.accentColor,
                mode: .liveRecording
            )
            .frame(height: 34)

            Text(Self.durationLabel(durationSeconds))
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)

            if isLocked {
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Color.accentColor, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Finish recording")
            } else {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    private static func durationLabel(_ duration: Double) -> String {
        let total = max(0, Int(duration.rounded(.down)))
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}

nonisolated enum AudioWaveformMode {
    case playback
    case liveRecording
}

nonisolated struct AudioWaveformBar: Equatable, Sendable {
    let amplitude: CGFloat?

    var isVisible: Bool {
        amplitude != nil
    }

    static var blank: AudioWaveformBar {
        AudioWaveformBar(amplitude: nil)
    }

    static func visible(_ amplitude: CGFloat) -> AudioWaveformBar {
        AudioWaveformBar(amplitude: min(1, max(0.05, amplitude)))
    }
}

nonisolated enum AudioWaveformPresentation {
    static let amplitudeCurveExponent: Double = 0.45

    static func bars(
        for samples: [CGFloat],
        mode: AudioWaveformMode,
        count: Int = MediaWaveformAnalyzer.sampleCount
    ) -> [AudioWaveformBar] {
        let targetCount = max(0, count)
        switch mode {
        case .playback:
            guard targetCount > 0 else { return [] }
            return MediaWaveformAnalyzer.normalized(samples, count: targetCount)
                .map(displayAmplitude)
                .map(AudioWaveformBar.visible)
        case .liveRecording:
            guard targetCount > 0 else { return [] }
            let visibleSamples = samples.suffix(targetCount)
                .map(displayAmplitude)
                .map(AudioWaveformBar.visible)
            let blankCount = max(0, targetCount - visibleSamples.count)
            return Array(repeating: AudioWaveformBar.blank, count: blankCount) + visibleSamples
        }
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
    var mode: AudioWaveformMode = .playback

    var body: some View {
        GeometryReader { geometry in
            let bars = AudioWaveformPresentation.bars(for: samples, mode: mode)
            let spacing: CGFloat = 2
            let barCount = max(1, bars.count)
            let availableWidth = geometry.size.width - spacing * CGFloat(max(0, barCount - 1))
            let barWidth = max(2, availableWidth / CGFloat(barCount))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(bars.enumerated()), id: \.offset) { index, bar in
                    if let sample = bar.amplitude {
                        let played = CGFloat(index) / CGFloat(max(1, bars.count - 1)) <= progress
                        Capsule()
                            .fill(played ? playedColor : barColor)
                            .frame(
                                width: barWidth,
                                height: max(4, geometry.size.height * min(1, max(0.08, sample)))
                            )
                    } else {
                        Capsule()
                            .fill(Color.clear)
                            .frame(width: barWidth, height: 4)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .accessibilityHidden(true)
    }
}
