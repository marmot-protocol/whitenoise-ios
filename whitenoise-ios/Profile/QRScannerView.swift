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

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan, onError: onError, validate: validate, onInvalidPayload: onInvalidPayload)
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

        init(
            onScan: @escaping (String) -> Void,
            onError: @escaping (QRScannerFailure) -> Void,
            validate: @escaping (String) -> Bool,
            onInvalidPayload: @escaping () -> Void
        ) {
            self.onScan = onScan
            self.onError = onError
            self.validate = validate
            self.onInvalidPayload = onInvalidPayload
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard !didScan,
                  let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let value = object.stringValue
            else { return }
            DispatchQueue.main.async { self.receive(value) }
        }

        func receive(_ payload: String) {
            guard !didScan else { return }
            didScan = true
            if validate(payload) {
                onScan(payload)
            } else {
                onInvalidPayload()
            }
        }

        func resumeScanning(attempt: Int) {
            guard scanAttempt != attempt else { return }
            scanAttempt = attempt
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
