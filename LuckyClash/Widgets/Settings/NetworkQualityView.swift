import Clash
import Observation
import SwiftUI

@MainActor
@Observable
private final class NetworkQualityDiagnostics {
    var qualityRunning = false
    var stunRunning = false
    var qualityProgress = ""
    var stunProgress = ""
    var qualityResult: String?
    var stunResult: String?
    private var qualityTest: ClashNetworkQualityTest?
    private var stunTest: ClashSTUNTest?
    private var qualityID = UUID()
    private var stunID = UUID()

    func startQuality() {
        guard !qualityRunning, let test = ClashNewNetworkQualityTest() else { return }
        qualityID = UUID()
        qualityTest = test
        qualityRunning = true
        qualityResult = nil
        qualityProgress = "准备中"
        let handler = QualityHandler(owner: self, id: qualityID)
        test.start(ClashNetworkQualityDefaultConfigURL, serial: false,
                   maxRuntimeSeconds: ClashNetworkQualityDefaultMaxRuntimeSeconds,
                   http3: false, handler: handler)
    }

    func startSTUN(server: String) {
        guard !stunRunning, let test = ClashNewSTUNTest() else { return }
        stunID = UUID()
        stunTest = test
        stunRunning = true
        stunResult = nil
        stunProgress = "正在连接"
        test.start(server, handler: STUNHandler(owner: self, id: stunID))
    }

    func cancelQuality() {
        qualityID = UUID()
        qualityTest?.cancel()
        qualityTest = nil
        qualityRunning = false
        qualityProgress = ""
    }

    func cancelSTUN() {
        stunID = UUID()
        stunTest?.cancel()
        stunTest = nil
        stunRunning = false
        stunProgress = ""
    }

    func qualityUpdate(id: UUID, text: String, finished: Bool) {
        guard id == qualityID else { return }
        if finished {
            qualityID = UUID()
            qualityResult = text
            qualityRunning = false
            qualityTest = nil
        } else {
            qualityProgress = text
        }
    }

    func stunUpdate(id: UUID, text: String, finished: Bool) {
        guard id == stunID else { return }
        if finished {
            stunID = UUID()
            stunResult = text
            stunRunning = false
            stunTest = nil
        } else {
            stunProgress = text
        }
    }
}

private nonisolated final class QualityHandler: NSObject, ClashNetworkQualityTestHandlerProtocol {
    weak var owner: NetworkQualityDiagnostics?
    let id: UUID

    init(owner: NetworkQualityDiagnostics, id: UUID) {
        self.owner = owner
        self.id = id
    }

    func onProgress(_ progress: ClashNetworkQualityProgress?) {
        guard let progress else { return }
        let phase: String
        switch progress.phase {
        case ClashNetworkQualityPhaseDownload: phase = "下载测速"
        case ClashNetworkQualityPhaseUpload: phase = "上传测速"
        default: phase = "正在测量"
        }
        let text = "\(phase) · \(progress.elapsedMs / 1000) 秒"
        Task { @MainActor [weak owner, id] in owner?.qualityUpdate(id: id, text: text, finished: false) }
    }

    func onResult(_ result: ClashNetworkQualityResult?) {
        guard let result else { onError("未返回测速结果"); return }
        let text = "下载 \(ClashFormatBitrate(result.downloadCapacity)) · 上传 \(ClashFormatBitrate(result.uploadCapacity))\n空闲延迟 \(result.idleLatencyMs) ms · 下载 \(result.downloadRPM) RPM · 上传 \(result.uploadRPM) RPM"
        Task { @MainActor [weak owner, id] in owner?.qualityUpdate(id: id, text: text, finished: true) }
    }

    func onError(_ message: String?) {
        let text = message ?? "网络质量测试失败"
        Task { @MainActor [weak owner, id] in owner?.qualityUpdate(id: id, text: text, finished: true) }
    }
}

private nonisolated final class STUNHandler: NSObject, ClashSTUNTestHandlerProtocol {
    weak var owner: NetworkQualityDiagnostics?
    let id: UUID

    init(owner: NetworkQualityDiagnostics, id: UUID) {
        self.owner = owner
        self.id = id
    }

    func onProgress(_ progress: ClashSTUNTestProgress?) {
        guard let progress else { return }
        let text: String
        switch progress.phase {
        case ClashSTUNPhaseNATMapping: text = "正在检测 NAT 映射"
        case ClashSTUNPhaseNATFiltering: text = "正在检测 NAT 过滤"
        default: text = "正在连接 STUN 服务器"
        }
        Task { @MainActor [weak owner, id] in owner?.stunUpdate(id: id, text: text, finished: false) }
    }

    func onResult(_ result: ClashSTUNTestResult?) {
        guard let result else { onError("未返回 STUN 结果"); return }
        let nat = result.natTypeSupported
            ? "映射 \(ClashFormatNATMapping(result.natMapping))\n过滤 \(ClashFormatNATFiltering(result.natFiltering))"
            : "服务器未提供 NAT 类型检测"
        let text = "公网地址 \(result.externalAddr)（\(ClashFormatSTUNAddressFamily(result.externalAddressFamily))）\n延迟 \(result.latencyMs) ms\n\(nat)"
        Task { @MainActor [weak owner, id] in owner?.stunUpdate(id: id, text: text, finished: true) }
    }

    func onError(_ message: String?) {
        let text = message ?? "STUN 测试失败"
        Task { @MainActor [weak owner, id] in owner?.stunUpdate(id: id, text: text, finished: true) }
    }
}

struct NetworkQualityView: View {
    @State private var diagnostics = NetworkQualityDiagnostics()
    @State private var stunServer = ClashSTUNDefaultServer

    var body: some View {
        Form {
            Section {
                if diagnostics.qualityRunning {
                    ProgressView(diagnostics.qualityProgress)
                    Button("取消测速") { diagnostics.cancelQuality() }
                } else {
                    Button("开始带宽与响应性测试") { diagnostics.startQuality() }
                }
                if let result = diagnostics.qualityResult { Text(result).textSelection(.enabled) }
            } header: {
                Text("网络质量")
            } footer: {
                Text("测试使用 Apple 网络质量服务，会产生上下行流量。")
            }
            Section("NAT 检测") {
                TextField("STUN 服务器", text: $stunServer)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .disabled(diagnostics.stunRunning)
                if diagnostics.stunRunning {
                    ProgressView(diagnostics.stunProgress)
                    Button("取消检测") { diagnostics.cancelSTUN() }
                } else {
                    Button("开始 NAT 检测") {
                        diagnostics.startSTUN(server: stunServer.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    .disabled(stunServer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let result = diagnostics.stunResult { Text(result).textSelection(.enabled) }
            }
        }
        .navigationTitle("网络质量")
        .onDisappear {
            diagnostics.cancelQuality()
            diagnostics.cancelSTUN()
        }
    }
}
