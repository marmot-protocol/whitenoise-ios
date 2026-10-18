import SwiftUI
import AVFoundation

/// Camera QR scanner. Presents a live preview, reports the first decoded
/// payload via `onScan`, and surfaces permission / hardware problems via
/// `onError`. The scanner reads the raw string; deep-link parsing happens in
/// the caller, so it works without any OS-level URL-scheme registration.
struct QRScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    let onError: (QRScannerFailure) -> Void
    var validate: (String) -> Bool = { _ in true }
    var onInvalidPayload: () -> Void = {}
    var scanAttempt = 0
    var continuesAfterInvalidPayload = false
    var previouslyScannedPayload: String?
    var onPreviousPayloadCleared: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onScan: onScan, onError: onError, validate: validate, onInvalidPayload: onInvalidPayload,
            continuesAfterInvalidPayload: continuesAfterInvalidPayload,
            previouslyScannedPayload: previouslyScannedPayload,
            onPreviousPayloadCleared: onPreviousPayloadCleared
        )
    }

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.coordinator = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {
        context.coordinator.resumeScanning(attempt: scanAttempt)
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let onScan: (String) -> Void
        let onError: (QRScannerFailure) -> Void
        private var didScan = false
        private var scanAttempt = 0
        private let validate: (String) -> Bool
        private let onInvalidPayload: () -> Void
        private let continuesAfterInvalidPayload: Bool
        private var lastRejectedPayload: String?
        private var hasReportedInvalidPayload = false
        private var previouslyScannedPayload: String?
        private var previousPayloadAbsentSince: ContinuousClock.Instant?
        private let onPreviousPayloadCleared: () -> Void

        init(
            onScan: @escaping (String) -> Void,
            onError: @escaping (QRScannerFailure) -> Void,
            validate: @escaping (String) -> Bool = { _ in true },
            onInvalidPayload: @escaping () -> Void = {},
            continuesAfterInvalidPayload: Bool = false,
            previouslyScannedPayload: String? = nil,
            onPreviousPayloadCleared: @escaping () -> Void = {}
        ) {
            self.onScan = onScan
            self.onError = onError
            self.validate = validate
            self.onInvalidPayload = onInvalidPayload
            self.continuesAfterInvalidPayload = continuesAfterInvalidPayload
            self.previouslyScannedPayload = previouslyScannedPayload
            self.onPreviousPayloadCleared = onPreviousPayloadCleared
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            let payloads = metadataObjects.compactMap {
                ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue
            }
            DispatchQueue.main.async { self.receiveFrame(payloads) }
        }

        func receive(_ payload: String) {
            receiveFrame([payload])
        }

        func receiveFrame(_ payloads: [String], at now: ContinuousClock.Instant = .now) {
            guard !didScan else { return }
            if let previouslyScannedPayload {
                if payloads.contains(previouslyScannedPayload) {
                    previousPayloadAbsentSince = nil
                } else if let absentSince = previousPayloadAbsentSince,
                          absentSince.duration(to: now) >= .seconds(1) {
                    // Only an observed absence can rearm this code; a callback gap cannot.
                    self.previouslyScannedPayload = nil
                    previousPayloadAbsentSince = nil
                    onPreviousPayloadCleared()
                } else if previousPayloadAbsentSince == nil {
                    previousPayloadAbsentSince = now
                }
            }
            var rejectedPayload: String?
            for payload in payloads where payload != previouslyScannedPayload {
                let alreadyRejected = continuesAfterInvalidPayload && payload == lastRejectedPayload
                if !alreadyRejected, validate(payload) {
                    didScan = true
                    onScan(payload)
                    return
                }
                rejectedPayload = payload
                // Explicit-retry scanners retain their first-code behavior.
                if !continuesAfterInvalidPayload { break }
            }
            guard let rejectedPayload else { return }
            didScan = !continuesAfterInvalidPayload
            lastRejectedPayload = rejectedPayload
            if !hasReportedInvalidPayload {
                hasReportedInvalidPayload = true
                onInvalidPayload()
            }
        }

        func resumeScanning(attempt: Int) {
            guard scanAttempt != attempt else { return }
            scanAttempt = attempt
            lastRejectedPayload = nil
            hasReportedInvalidPayload = false
            didScan = false
        }

    }
}

/// UIKit host for the capture session.
final class ScannerViewController: UIViewController {
    weak var coordinator: QRScannerView.Coordinator?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    /// Serializes `startRunning()` / `stopRunning()` so a stop enqueued after a
    /// start always runs after it. Avoids the race where a fast dismiss skips
    /// the stop because `isRunning` hasn't flipped to `true` yet.
    private let sessionQueue = DispatchQueue(label: "dev.ipf.whitenoise.qr-scanner.session")

    private var permissionTask: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        NotificationCenter.default.addObserver(
            self, selector: #selector(captureFailed), name: AVCaptureSession.runtimeErrorNotification, object: session
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(captureInterrupted(_:)), name: AVCaptureSession.wasInterruptedNotification, object: session
        )
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        permissionTask?.cancel()
        permissionTask = Task { @MainActor [weak self] in
            let authorization = AVCaptureDevice.authorizationStatus(for: .video)
            if let failure = QRScannerFailure.preflight(
                authorization: authorization, hasCamera: AVCaptureDevice.default(for: .video) != nil
            ) {
                guard !Task.isCancelled else { return }
                self?.coordinator?.onError(failure)
                return
            }
            let granted = authorization == .authorized ? true : await AVCaptureDevice.requestAccess(for: .video)
            guard !Task.isCancelled, let self else { return }
            guard granted else {
                coordinator?.onError(
                    AVCaptureDevice.authorizationStatus(for: .video) == .restricted ? .restricted : .denied
                )
                return
            }
            if preview == nil { configureSession() }
            else { sessionQueue.async { [session] in session.startRunning() } }
        }
    }

    @objc private func captureFailed() {
        Task { @MainActor [weak self] in
            guard let self, viewIfLoaded?.window != nil else { return }
            coordinator?.onError(.configurationFailed)
        }
    }

    @objc private func captureInterrupted(_ notification: Notification) {
        let reason = (notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue
        let failure = QRScannerFailure.interruption(reason: reason)
        Task { @MainActor [weak self] in
            guard let self, viewIfLoaded?.window != nil else { return }
            coordinator?.onError(failure)
        }
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video) else {
            coordinator?.onError(.noCamera)
            return
        }
        guard let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else {
            coordinator?.onError(.configurationFailed)
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            coordinator?.onError(.configurationFailed)
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(coordinator, queue: .main)
        guard output.availableMetadataObjectTypes.contains(.qr) else {
            coordinator?.onError(.configurationFailed)
            return
        }
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.layer.bounds
        view.layer.addSublayer(layer)
        preview = layer

        // Start on the dedicated serial queue so any stop enqueued later (e.g.
        // a fast dismiss) is guaranteed to run after this start completes.
        sessionQueue.async { [session] in session.startRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.layer.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        permissionTask?.cancel()
        // Serialize the stop behind any in-flight `startRunning()` on the same
        // queue, so the camera is always released even on a fast dismiss that
        // races the asynchronous start. By the time this runs the start has
        // completed, so `isRunning` is observed reliably.
        sessionQueue.async { [session] in
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    deinit {
        permissionTask?.cancel()
        // Backstop: ensure the capture session is torn down even if a lifecycle
        // callback is skipped, so the camera hardware never leaks.
        sessionQueue.async { [session] in
            if session.isRunning {
                session.stopRunning()
            }
        }
    }
}
