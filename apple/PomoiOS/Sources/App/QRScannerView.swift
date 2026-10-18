import AVFoundation
import SwiftUI
import UIKit

/// A camera preview that reports every QR code it reads as a string. Asks for camera permission on first use.
struct QRScannerView: UIViewControllerRepresentable {
    var onScan: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let c = ScannerController()
        c.onScan = onScan
        return c
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {
        controller.onScan = onScan
    }
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: (String) -> Void = { _ in }

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "dev.hamardikan.pomo.scanner")
    private var preview: AVCaptureVideoPreviewLayer?
    private let message = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        message.textColor = .white
        message.textAlignment = .center
        message.numberOfLines = 0
        message.font = .preferredFont(forTextStyle: .body)
        message.adjustsFontForContentSizeCategory = true
        message.isHidden = true
        message.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(message)
        NSLayoutConstraint.activate([
            message.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            message.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            message.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { granted ? self.configure() : self.show("Camera access is off. Allow it in Settings to scan the code, or paste the ticket instead.") }
            }
        default:
            show("Camera access is off. Allow it in Settings to scan the code, or paste the ticket instead.")
        }
    }

    private func show(_ text: String) {
        message.text = text
        message.isHidden = false
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else {
            show("No camera is available. Paste the ticket instead.")
            return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, at: 0)
        preview = layer
        let session = self.session
        sessionQueue.async { session.startRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let session = self.session
        sessionQueue.async { if session.isRunning { session.stopRunning() } }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection
    ) {
        for case let code as AVMetadataMachineReadableCodeObject in objects {
            if let text = code.stringValue { onScan(text) }
        }
    }
}
