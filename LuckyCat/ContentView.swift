import NetworkExtension
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("wireGuardPrototypeDisclosureAccepted") private var acceptedDisclosure = false
    @State private var vpn = PrototypeVPN()
    @State private var showingImporter = false
    @State private var showingDisclosure = false

    var body: some View {
        NavigationStack {
            Form {
                Section("WireGuard 测试隧道") {
                    LabeledContent("状态", value: statusLabel)
                    if let endpoint = vpn.imported?.endpoint ?? vpn.savedEndpoint {
                        LabeledContent(vpn.imported == nil ? "远端" : "待保存远端", value: endpoint)
                    }
                    if let message = vpn.message {
                        Label(message, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    Button("导入测试配置", systemImage: "document.badge.plus") {
                        showingImporter = true
                    }
                    .disabled(vpn.busy || vpn.isActive)

                    if vpn.isActive {
                        Button("断开", systemImage: "stop.circle") { vpn.disconnect() }
                            .disabled(vpn.busy || !vpn.canStop)
                    } else {
                        Button("连接", systemImage: "bolt.shield") {
                            if acceptedDisclosure {
                                Task { await vpn.connect() }
                            } else {
                                showingDisclosure = true
                            }
                        }
                        .disabled(vpn.busy || (vpn.imported == nil && vpn.savedEndpoint == nil))
                    }
                } footer: {
                    Text("使用团队控制的 WireGuard 测试远端。断开后，iOS 会恢复普通网络访问。")
                }
            }
            .navigationTitle("LuckyCat")
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url): vpn.importFile(url)
                case .failure: vpn.message = "无法打开测试配置文件。"
                }
            }
            .alert("使用测试隧道", isPresented: $showingDisclosure) {
                Button("取消", role: .cancel) {}
                Button("同意并连接") {
                    acceptedDisclosure = true
                    Task { await vpn.connect() }
                }
            } message: {
                Text("配置及密钥保存在本机钥匙串。系统纳入 VPN 的 IP 流量及 DNS 请求会经由你导入的测试远端转发。系统路由例外和远端地址本身仍可走普通网络。LuckyCat 不上传日志。")
            }
        }
        .task { await vpn.refresh() }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                Task { await vpn.refresh() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NEVPNStatusDidChange)) { _ in
            Task { await vpn.updateStatus() }
        }
    }

    private var statusLabel: String {
        if vpn.requestingConnection { return "正在请求连接" }
        switch vpn.status {
        case .invalid: return "未配置"
        case .disconnected: return "已断开"
        case .connecting: return "连接中"
        case .connected: return "已连接"
        case .reasserting: return "重连中"
        case .disconnecting: return "断开中"
        @unknown default: return "未知"
        }
    }
}

#Preview {
    ContentView()
}
