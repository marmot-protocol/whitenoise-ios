import SwiftUI

/// Floats above the thumb during a hold: slide up to the lock to keep
/// recording or dictating hands-free.
struct HoldLockHint: View {
    /// Center of the hint above the composer's top edge, clear of the thumb.
    static let liftAboveComposer: CGFloat = 64

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 0 at rest, 1 when the slide reaches the lock.
    let progress: CGFloat
    @State private var nudged = false

    @ScaledMetric(relativeTo: .body) private var width: CGFloat = 40
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 84

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: progress >= 1 ? "lock.fill" : "lock")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
            Image(systemName: "chevron.up")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.secondary)
                .offset(y: nudged ? -4 : 2)
                .opacity(1 - progress)
        }
        .frame(width: width, height: height)
        .compatibleInputCapsuleChrome(interactive: false)
        // Rises with the finger so the slide reads as reaching for the lock.
        .offset(y: -12 * progress)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                nudged = true
            }
        }
        .accessibilityHidden(true)
    }
}

/// Sizes the red bubble under the thumb while a voice message records.
enum VoiceRecordingBubbleMetrics {
    /// Wide enough to show around a thumb.
    static let diameter: CGFloat = 84
    static let restingHaloScale: CGFloat = 1.08
    static let loudestHaloScale: CGFloat = 1.4

    /// The ring around the bubble grows with the microphone level (0...1).
    static func haloScale(level: CGFloat) -> CGFloat {
        let clamped = min(1, max(0, level))
        return restingHaloScale + (loudestHaloScale - restingHaloScale) * clamped
    }

    /// The lock hint floats this far above the composer during a voice
    /// hold, so the loudest ring stays clear of it.
    static let lockHintLift: CGFloat = 104
}

/// The red bubble under the thumb while a voice message records: it
/// breathes steadily and its ring swells with the voice, so it reads as
/// live even under a finger.
struct VoiceRecordingBubble: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The latest microphone level, 0...1.
    let level: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.red.opacity(0.28))
                .scaleEffect(
                    reduceMotion
                        ? VoiceRecordingBubbleMetrics.restingHaloScale
                        : VoiceRecordingBubbleMetrics.haloScale(level: level)
                )
                .animation(.easeOut(duration: 0.12), value: level)
            if reduceMotion {
                Circle().fill(Color.red)
            } else {
                Circle()
                    .fill(Color.red)
                    .phaseAnimator([CGFloat(0.94), 1.02]) { circle, scale in
                        circle.scaleEffect(scale)
                    } animation: { _ in
                        .easeInOut(duration: 0.7)
                    }
            }
        }
        .frame(width: VoiceRecordingBubbleMetrics.diameter, height: VoiceRecordingBubbleMetrics.diameter)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The message field while a voice message records: a blinking dot, the
/// elapsed time, and, until it locks, the slide-left-to-cancel prompt.
struct ComposerVoiceRecordingStatus: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let durationSeconds: Double
    let isLocked: Bool
    /// The finger's horizontal travel; the prompt follows it left.
    let dragX: CGFloat
    @State private var dimmed = false

    var body: some View {
        let elapsed = AudioDurationLabel.label(for: durationSeconds)
        HStack(spacing: 8) {
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
                .opacity(dimmed ? 0.25 : 1)
            Text(elapsed)
                .font(.body.monospacedDigit())
                .foregroundStyle(.red)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            if !isLocked {
                slideToCancel
                    .padding(.leading, 20)
                    .offset(x: min(0, dragX))
                    .opacity(1 - HoldGesturePolicy.cancelProgress(CGSize(width: dragX, height: 0)))
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, minHeight: ComposerInputChrome.controlSize)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                dimmed = true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.formatted("Recording, %@", elapsed))
    }

    /// Drifts gently left and back to hint at the slide.
    @ViewBuilder
    private var slideToCancel: some View {
        let prompt = HStack(spacing: 4) {
            // Physical left: the gesture is a leftward slide in every layout direction.
            Image(systemName: "chevron.left")
                .font(.footnote.weight(.semibold))
            Text(L10n.string("Slide to cancel"))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)

        if reduceMotion {
            prompt
        } else {
            prompt
                .phaseAnimator([CGFloat(0), -6]) { content, drift in
                    content.offset(x: drift)
                } animation: { _ in
                    .easeInOut(duration: 0.9)
                }
        }
    }
}
