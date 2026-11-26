import AVFoundation
import PhotosUI
import SwiftUI
import UIKit

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
        ZStack {
            Color.black.ignoresSafeArea()
            if authorization == .authorized && cameraAvailable {
                QRScannerView { handle($0) }
                    .ignoresSafeArea()
            }

            VStack(spacing: 0) {
                header
                scannerArea
                footer
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .accessibilityAction(.escape) { dismiss() }
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

    private var header: some View {
        Text("二维码导入")
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, 64)
            .frame(maxWidth: .infinity, minHeight: 44)
            .overlay(alignment: .topLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.55), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("取消")
                .padding(.leading, 16)
            }
            .padding(.vertical, 8)
            .background {
                LinearGradient(colors: [.black.opacity(0.8), .black.opacity(0.55)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea(edges: .top)
            }
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Text("支持订阅链接、clash:// 链接和分享链接")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
            albumButton
            if let error {
                Text(error)
                    .foregroundStyle(.orange)
                    .font(.footnote)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background {
            LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.9)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    @ViewBuilder private var scannerArea: some View {
        switch authorization {
        case .authorized:
            if cameraAvailable {
                scannerOverlay
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
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let side = min(280, bounds.width * 0.64, bounds.height * 0.54)
            let frame = CGRect(x: bounds.midX - side / 2, y: bounds.height * 0.43 - side / 2,
                               width: side, height: side)
            let radius = min(22, side * 0.12)

            ZStack(alignment: .top) {
                Path { path in
                    path.addRect(bounds)
                    path.addRoundedRect(in: frame, cornerSize: CGSize(width: radius, height: radius))
                }
                .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
                .accessibilityHidden(true)

                QRScanCorners(radius: radius)
                    .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: side, height: side)
                    .position(x: frame.midX, y: frame.midY)
                    .accessibilityHidden(true)

                Text("将配置二维码放入取景框")
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, frame.maxY + 16)
            }
        }
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
            Label("从相册选择", systemImage: "photo.on.rectangle")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .frame(minHeight: 44)
                .background(.white.opacity(0.16), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("从相册选择二维码")
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

private struct QRScanCorners: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let length = min(36, rect.width * 0.2)
        let corner = Path { path in
            path.move(to: CGPoint(x: 0, y: length))
            path.addLine(to: CGPoint(x: 0, y: radius))
            path.addQuadCurve(to: CGPoint(x: radius, y: 0), control: .zero)
            path.addLine(to: CGPoint(x: length, y: 0))
        }

        return Path { path in
            path.addPath(corner, transform: CGAffineTransform(translationX: rect.minX, y: rect.minY))
            path.addPath(corner, transform: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: rect.maxX, ty: rect.minY))
            path.addPath(corner, transform: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: rect.minX, ty: rect.maxY))
            path.addPath(corner, transform: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: rect.maxX, ty: rect.maxY))
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
