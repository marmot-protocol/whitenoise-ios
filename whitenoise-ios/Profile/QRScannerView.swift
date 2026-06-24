import SwiftUI
import AVFoundation

/// Camera QR scanner. Presents a live preview, reports the first decoded
/// payload via `onScan`, and surfaces permission / hardware problems via
/// `onError`. The scanner reads the raw string; deep-link parsing happens in
/// the caller, so it works without any OS-level URL-scheme registration.
struct QRScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan, onError: onError)
    }

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.coordinator = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let onScan: (String) -> Void
        let onError: (String) -> Void
        private var didScan = false

        init(onScan: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
            self.onScan = onScan
            self.onError = onError
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
            didScan = true
            DispatchQueue.main.async { self.onScan(value) }
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

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                if granted {
                    self.configureSession()
                } else {
                    self.coordinator?.onError(L10n.string("Camera access denied. Enable it in Settings to scan QR codes."))
                }
            }
        }
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else {
            coordinator?.onError(L10n.string("No camera available on this device."))
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            coordinator?.onError(L10n.string("Couldn't start the camera."))
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(coordinator, queue: .main)
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
        // Backstop: ensure the capture session is torn down even if a lifecycle
        // callback is skipped, so the camera hardware never leaks.
        sessionQueue.async { [session] in
            if session.isRunning {
                session.stopRunning()
            }
        }
    }
}
