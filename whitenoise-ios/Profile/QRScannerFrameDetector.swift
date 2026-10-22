import AVFoundation
import Vision

/// Connect uses empty-frame observations to clear invalid-code feedback without repeating it.
nonisolated final class QRScannerFrameDetector: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    struct Frame: Sendable {
        let payloads: [String]
        let observedAt: ContinuousClock.Instant
    }

    let frames: AsyncStream<Frame>
    let queue = DispatchQueue(label: "dev.ipf.whitenoise.qr-scanner.frames")
    private let continuation: AsyncStream<Frame>.Continuation
    // Accessed only by the serial video-output delegate queue.
    private var lastObservation: ContinuousClock.Instant?

    override init() {
        (frames, continuation) = AsyncStream<Frame>.makeStream(bufferingPolicy: .bufferingNewest(1))
        super.init()
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = ContinuousClock.now
        guard lastObservation.map({ $0.duration(to: now) >= .milliseconds(200) }) ?? true else { return }
        lastObservation = now
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        do {
            let payloads = try Self.payloads(in: VNImageRequestHandler(cvPixelBuffer: buffer))
            continuation.yield(Frame(payloads: payloads, observedAt: now))
        } catch {
            // A failed analysis is not evidence that the previous code left the frame.
        }
    }

    static func payloads(in handler: VNImageRequestHandler) throws -> [String] {
        let request = VNDetectBarcodesRequest()
        #if targetEnvironment(simulator)
        // Newer revisions depend on inference unavailable in Simulator.
        // Revision 1 still decodes real QR pixels for the frame-to-feedback test.
        request.revision = VNDetectBarcodesRequestRevision1
        #endif
        request.symbologies = [.qr]
        try handler.perform([request])
        return request.results?.compactMap(\.payloadStringValue) ?? []
    }

    deinit {
        continuation.finish()
    }
}
