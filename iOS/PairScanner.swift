import SwiftUI
import AVFoundation
import UIKit

struct PairScanner: View {
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    let onCode: (String) -> Bool
    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                CameraPreview(onCode: onCode, onError: { error = $0 })
                    .ignoresSafeArea(edges: .bottom)
                if let error {
                    Text(error).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).padding()
                }
            }
            .navigationTitle("扫描 Mac 配对码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("取消") { dismiss() } }
        }
    }
}

private struct CameraPreview: UIViewControllerRepresentable {
    let onCode: (String) -> Bool
    let onError: (String) -> Void
    func makeUIViewController(context: Context) -> CameraController {
        CameraController(onCode: onCode, onError: onError)
    }
    func updateUIViewController(_ controller: CameraController, context: Context) {}
    static func dismantleUIViewController(_ controller: CameraController, coordinator: ()) { controller.stop() }
}

private final class CameraController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "remotemic.qr.camera")
    private var preview: AVCaptureVideoPreviewLayer?
    private var finished = false
    private var visible = false
    private var configured = false
    private let onCode: (String) -> Bool
    private let onError: (String) -> Void
    init(onCode: @escaping (String) -> Bool, onError: @escaping (String) -> Void) {
        self.onCode = onCode; self.onError = onError
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview); self.preview = preview
        NotificationCenter.default.addObserver(self, selector: #selector(background), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(foreground), name: UIApplication.didBecomeActiveNotification, object: nil)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated); visible = true; authorize()
    }
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); stop() }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews(); preview?.frame = view.bounds
        let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
        let angle: CGFloat
        switch orientation {
        case .landscapeLeft: angle = 0
        case .landscapeRight: angle = 180
        case .portraitUpsideDown: angle = 270
        default: angle = 90
        }
        if let connection = preview?.connection, connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
    }
    private func authorize() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                DispatchQueue.main.async {
                    guard let self, self.visible else { return }
                    if allowed { self.start() } else { self.onError("相机权限未开启，可在设置中允许，或返回粘贴配对链接") }
                }
            }
        default: onError("相机权限未开启，可在设置中允许，或返回粘贴配对链接")
        }
    }
    private func start() {
        guard visible, !finished else { return }
        queue.async { [self] in
            if !configured {
                guard let camera = AVCaptureDevice.default(for: .video),
                      let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else {
                    DispatchQueue.main.async { self.onError("相机不可用，请返回粘贴配对链接") }; return
                }
                session.beginConfiguration(); session.addInput(input)
                let output = AVCaptureMetadataOutput()
                guard session.canAddOutput(output) else {
                    session.removeInput(input); session.commitConfiguration()
                    DispatchQueue.main.async { self.onError("无法启动扫码，请返回粘贴配对链接") }; return
                }
                session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                output.metadataObjectTypes = [.qr]
                session.commitConfiguration(); configured = true
            }
            if !session.isRunning { session.startRunning() }
        }
    }
    func stop() { visible = false; queue.async { [self] in if session.isRunning { session.stopRunning() } } }
    @objc private func background() { queue.async { [self] in if session.isRunning { session.stopRunning() } } }
    @objc private func foreground() { if visible { authorize() } }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard visible, !finished, let code = objects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first else { return }
        if onCode(code) { finished = true; stop() }
        else { onError("不是 Remote Microphone 配对码，请扫描 Mac 内的二维码") }
    }
    deinit { NotificationCenter.default.removeObserver(self) }
}
