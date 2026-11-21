import AVFoundation
import CoreImage
import PhotosUI
import SwiftUI
import UIKit

nonisolated enum QRCodePayload {
    /// Extracts the subscription URL from a FlClash-style QR payload. The code
    /// may hold a plain HTTPS link or a `clash://install-config?url=` /
    /// `luckyclash://install-config?url=` deep link.
    static func subscriptionURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let components = URLComponents(string: trimmed),
           let scheme = components.scheme?.lowercased(),
           ["clash", "luckyclash"].contains(scheme) {
            let target = components.queryItems?
                .first(where: { $0.name.lowercased() == "url" })?.value
            return target.flatMap { RemoteImport.url(from: $0) }
        }
        return RemoteImport.url(from: trimmed)
    }

    /// Decodes the first QR code in an image picked from the photo library.
    static func decode(imageData: Data) -> String? {
        guard let image = CIImage(data: imageData),
              let detector = CIDetector(
                ofType: CIDetectorTypeQRCode,
                context: nil,
                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
              ) else {
            return nil
        }
        return (detector.features(in: image) as? [CIQRCodeFeature])?
            .compactMap(\.messageString)
            .first
    }
}

struct QRCodeImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var authorization = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var photoItem: PhotosPickerItem?
    @State private var error: String?

    let onCode: (String) -> Void

    private var cameraAvailable: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
            || AVCaptureDevice.default(for: .video) != nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                scannerArea
                albumButton
                    .padding(.horizontal)
                    .padding(.vertical, 16)
                if let error {
                    Text(error)
                        .foregroundStyle(.orange)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                        .padding(.bottom, 12)
                }
            }
            .navigationTitle("二维码导入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .task {
                if authorization == .notDetermined {
                    _ = await AVCaptureDevice.requestAccess(for: .video)
                    authorization = AVCaptureDevice.authorizationStatus(for: .video)
                }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task { await decode(item) }
            }
        }
    }

    @ViewBuilder private var scannerArea: some View {
        switch authorization {
        case .authorized:
            if cameraAvailable {
                ZStack {
                    QRScannerView { handle($0) }
                        .ignoresSafeArea(edges: .bottom)
                    scannerOverlay
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
            } else {
                unavailable("当前设备没有可用的相机", systemImage: "camera.fill")
            }
        case .denied, .restricted:
            unavailable("允许相机访问后即可扫描二维码，或从相册选择二维码图片。", systemImage: "camera.metering.unknown") {
                Button("打开系统设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
            }
        default:
            VStack(spacing: 12) {
                ProgressView()
                Text("正在请求相机权限…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var scannerOverlay: some View {
        VStack {
            Spacer()
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.9), lineWidth: 3)
                .frame(width: 240, height: 240)
            Text("将配置二维码放入取景框")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .padding(.top, 16)
            Spacer()
            Text("支持订阅链接、clash:// 链接和分享链接")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.75))
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.25))
        .allowsHitTesting(false)
    }

    private func unavailable(
        _ message: String,
        systemImage: String,
        @ViewBuilder action: () -> some View = { EmptyView() }
    ) -> some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            action()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var albumButton: some View {
        PhotosPicker(selection: $photoItem, matching: .images) {
            Label("从相册选择二维码", systemImage: "photo.on.rectangle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("qr-photo-picker")
    }

    private func handle(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            error = "二维码内容为空。"
            return
        }
        onCode(trimmed)
    }

    private func decode(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                error = "无法读取所选图片。"
                return
            }
            let code = await Task.detached(priority: .userInitiated) {
                QRCodePayload.decode(imageData: data)
            }.value
            guard let code else {
                error = "所选图片中没有识别到二维码。"
                return
            }
            error = nil
            handle(code)
        } catch {
            self.error = "无法读取所选图片。"
        }
    }
}

private struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerController {
        let controller = QRScannerController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: QRScannerController, context: Context) {
        controller.onCode = onCode
    }
}

private final class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var handled = false

    var onCode: ((String) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            return
        }
        session.beginConfiguration()
        session.sessionPreset = .high
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        session.commitConfiguration()

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        previewLayer = layer
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard !session.isRunning else { return }
        let session = session
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard session.isRunning else { return }
        let session = session
        DispatchQueue.global(qos: .userInitiated).async {
            session.stopRunning()
        }
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let value = object.stringValue,
              !value.isEmpty else {
            return
        }
        Task { @MainActor [weak self] in
            guard let self, !self.handled else { return }
            self.handled = true
            self.session.stopRunning()
            self.onCode?(value)
        }
    }
}

#if DEBUG
/// Previews render the permission or no-camera state; the camera itself is not
/// available in the Xcode canvas.
#Preview("二维码导入") {
    QRCodeImportView { _ in }
}
#endif
