import NetworkExtension
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    private enum Page: Hashable { case connection, profiles, settings }

    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("tunnelDisclosureVersion") private var disclosureVersion = 0
    @State private var vpn = PrototypeVPN()
    @State private var page = Page.connection
    @State private var showingImporter = false
    @State private var showingPaste = false
    @State private var showingPreview = false
    @State private var showingDisclosure = false
    @State private var pendingDeletion: Profile?

    private static let disclosure = "LuckyCat 将配置和凭据保存在本机。纳入系统 VPN 路由的 IP 流量和 DNS 请求由你选择的远端转发。远端地址和 iOS 系统例外可走普通网络。断开后，iOS 可能恢复普通网络访问。LuckyCat 不上传配置、流量或诊断。"

    var body: some View {
        TabView(selection: $page) {
            connection.tabItem { Label("连接", systemImage: "bolt.shield") }.tag(Page.connection)
            profiles.tabItem { Label("配置", systemImage: "folder") }.tag(Page.profiles)
            settings.tabItem { Label("设置", systemImage: "gearshape") }.tag(Page.settings)
        }
        .task { await vpn.refresh() }
        .onChange(of: scenePhase) {
            if scenePhase == .active { Task { await vpn.refresh() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NEVPNStatusDidChange)) { _ in
            Task { await vpn.updateStatus() }
        }
    }

    private var connection: some View {
        NavigationStack {
            Form {
                Section("VPN") {
                    LabeledContent("状态", value: statusLabel)
                    if let profile = vpn.library.selectedProfile, let node = profile.selectedNode {
                        LabeledContent("配置", value: profile.name)
                        LabeledContent("节点", value: node.name)
                        LabeledContent("远端", value: node.endpoint)
                    } else if let endpoint = vpn.savedEndpoint {
                        LabeledContent("测试远端", value: endpoint)
                    }
                    feedback
                }

                Section {
                    if vpn.isActive {
                        Button("断开", systemImage: "stop.circle") { vpn.disconnect() }
                            .disabled(vpn.busy || !vpn.canStop)
                    } else if vpn.library.selectedProfile != nil || vpn.savedEndpoint != nil {
                        Button("连接", systemImage: "bolt.shield") {
                            if disclosureVersion == 1 {
                                Task { await vpn.connect() }
                            } else {
                                showingDisclosure = true
                            }
                        }
                        .disabled(vpn.busy)
                        .accessibilityIdentifier("connect-vpn")
                    } else {
                        Button("导入配置", systemImage: "document.badge.plus") { page = .profiles }
                    }
                }
            }
            .navigationTitle("LuckyCat")
            .alert("VPN 数据使用", isPresented: $showingDisclosure) {
                Button("取消", role: .cancel) {}
                Button("同意并连接") {
                    disclosureVersion = 1
                    Task { await vpn.connect() }
                }
            } message: {
                Text(Self.disclosure)
            }
        }
    }

    private var profiles: some View {
        NavigationStack {
            Form {
                Section {
                    Button("从文件导入", systemImage: "document.badge.plus") { showingImporter = true }
                    Button("粘贴配置", systemImage: "clipboard") { showingPaste = true }
                    if let error = vpn.importError { Text(error).foregroundStyle(.orange) }
                    feedback
                }
                .disabled(vpn.busy || vpn.isActive)

                ForEach(vpn.library.profiles) { profile in
                    Section(profile.name) {
                        ForEach(profile.nodes) { node in
                            Button {
                                vpn.select(profileID: profile.id, nodeID: node.id)
                            } label: {
                                LabeledContent {
                                    if vpn.library.selectedProfileID == profile.id, profile.selectedNodeID == node.id {
                                        Image(systemName: "checkmark").accessibilityLabel("当前节点")
                                    }
                                } label: {
                                    Text(node.name)
                                    Text(node.endpoint)
                                }
                            }
                            .disabled(vpn.busy || vpn.isActive)
                        }
                        Button("删除配置", role: .destructive) { pendingDeletion = profile }
                            .accessibilityIdentifier("delete-profile-\(profile.name)")
                            .disabled(vpn.busy || vpn.isActive)
                    }
                }
                if vpn.isActive {
                    Text("断开 VPN 后可切换、导入或删除配置。").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("配置")
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.yaml, .json, .plainText]) { result in
                switch result {
                case .success(let url):
                    vpn.importFile(url)
                    showingPreview = !vpn.imported.isEmpty
                case .failure(let error):
                    if (error as NSError).code != NSUserCancelledError {
                        vpn.message = "无法打开配置文件。"
                    }
                }
            }
            .sheet(isPresented: $showingPaste, onDismiss: {
                showingPreview = !vpn.imported.isEmpty
            }) {
                PasteConfiguration { text in
                    vpn.stage(Data(text.utf8))
                    return vpn.imported.isEmpty ? vpn.importError : nil
                }
            }
            .sheet(isPresented: $showingPreview, onDismiss: vpn.discardImport) {
                if let first = vpn.imported.first {
                    ImportPreview(vpn: vpn, selectedNode: first.id)
                }
            }
            .alert("删除配置？", isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ), presenting: pendingDeletion) { profile in
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) { Task { await vpn.remove(profile) } }
            } message: { profile in
                Text("将从本机删除「\(profile.name)」及其节点凭据。")
            }
        }
    }

    private var settings: some View {
        NavigationStack {
            List {
                NavigationLink("隐私与数据使用") {
                    List { Text(Self.disclosure) }
                        .navigationTitle("隐私与数据使用")
                }
                NavigationLink("配置兼容性") {
                    List {
                        Text("支持 Clash YAML 的 proxies 节点列表，以及原 WireGuard 测试 JSON。节点需使用 WireGuard、IP 字面量远端、双栈客户端地址和 1–3 个隧道内 DNS 地址。")
                        Text("YAML 每个节点使用 name、type、server、port、ip、ipv6、private-key、public-key 和 dns。dns 使用同一行的列表，udp 可省略或填 true。暂不支持规则、策略组、域名端点或 YAML 别名。")
                    }
                    .navigationTitle("配置兼容性")
                }
                NavigationLink("本地诊断") {
                    List {
                        if vpn.diagnostics.isEmpty {
                            Text("本次运行暂无诊断记录。")
                        } else {
                            Section {
                                Text(vpn.diagnostics.joined(separator: "\n"))
                                    .font(.footnote.monospaced())
                                    .textSelection(.enabled)
                            }
                            ShareLink(item: vpn.diagnostics.joined(separator: "\n")) {
                                Label("导出诊断", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                    .navigationTitle("本地诊断")
                }
            }
            .navigationTitle("设置")
        }
    }

    @ViewBuilder private var feedback: some View {
        if let message = vpn.message {
            Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
        }
    }

    private var statusLabel: String {
        if vpn.requestingConnection { return "正在请求连接" }
        if vpn.isActive && !vpn.canStop { return "断开中" }
        switch vpn.status {
        case .invalid: return vpn.library.selectedProfile == nil ? "未配置" : "已断开"
        case .disconnected: return "已断开"
        case .connecting: return "连接中"
        case .connected: return "已连接"
        case .reasserting: return "重连中"
        case .disconnecting: return "断开中"
        @unknown default: return "未知"
        }
    }
}

private struct PasteConfiguration: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?
    let parse: (String) -> String?

    var body: some View {
        NavigationStack {
            Form {
                TextEditor(text: $text)
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .frame(minHeight: 200)
                    .accessibilityLabel("配置内容")
                if let error { Text(error).foregroundStyle(.orange) }
            }
            .navigationTitle("粘贴配置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("预览") {
                        error = parse(text)
                        if error == nil { dismiss() }
                    }
                    .disabled(text.isEmpty)
                }
            }
        }
    }
}

private struct ImportPreview: View {
    @Environment(\.dismiss) private var dismiss
    let vpn: PrototypeVPN
    @State var selectedNode: String
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("配置名称", text: $name)
                Section("选择默认节点") {
                    Picker("节点", selection: $selectedNode) {
                        ForEach(vpn.imported) { node in
                            Text("\(node.name) · \(node.configuration.endpoint)").tag(node.id)
                        }
                    }
                    .pickerStyle(.inline)
                }
                if let error = vpn.importError { Text(error).foregroundStyle(.orange) }
            }
            .navigationTitle("导入预览")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let title = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
                        if vpn.saveImport(named: title.isEmpty ? selectedNode : title, selectedNode: selectedNode) {
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
