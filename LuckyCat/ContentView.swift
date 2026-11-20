import NetworkExtension
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    private enum Page: Hashable { case connection, profiles, settings }

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @AppStorage("tunnelDisclosureVersion") private var disclosureVersion = 0
    @State private var vpn = PrototypeVPN()
    @State private var page = Page.connection
    @State private var showingImporter = false
    @State private var showingPaste = false
    @State private var showingURLImport = false
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
                    if vpn.isActive {
                        LabeledContent("扩展", value: extensionLabel)
                    }
                    feedback
                }

                Section {
                    if vpn.library.selectedProfile == nil && vpn.savedEndpoint == nil {
                        Button("导入配置", systemImage: "document.badge.plus") { page = .profiles }
                    } else {
                        Toggle(isOn: connectionBinding) {
                            Label("连接", systemImage: "bolt.shield")
                        }
                        .disabled(connectToggleDisabled)
                        .accessibilityIdentifier("connect-vpn")
                    }
                } footer: {
                    if vpn.library.selectedProfile == nil && vpn.savedEndpoint == nil {
                        Text("导入配置后才能连接。")
                    } else if vpn.isActive {
                        Text("断开后，iOS 可能恢复普通网络访问。")
                    } else {
                        Text("首次连接前会说明数据使用方式。")
                    }
                }

                Section {
                    Picker("分流模式", selection: modeBinding) {
                        ForEach(TrafficMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(vpn.busy || vpn.isActive)
                    .accessibilityIdentifier("mode-picker")
                } header: {
                    Text("分流模式")
                } footer: {
                    Text(modeExplanation)
                }

                if let issue = vpn.issue, issue != .storage {
                    Section("恢复") {
                        recovery(issue)
                    }
                }

                if vpn.isActive, let traffic = vpn.traffic {
                    Section {
                        LabeledContent("接收", value: Self.bytes(traffic.received))
                        LabeledContent("发送", value: Self.bytes(traffic.sent))
                        LabeledContent("更新", value: traffic.updatedAt.formatted(date: .omitted, time: .standard))
                    } header: {
                        Text("流量")
                    } footer: {
                        Text("由扩展按聚合值每 5 秒上报，仅显示在本机。")
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

    private var connectionBinding: Binding<Bool> {
        Binding(
            get: { vpn.isActive },
            set: { on in
                if on {
                    if disclosureVersion == 1 {
                        Task { await vpn.connect() }
                    } else {
                        showingDisclosure = true
                    }
                } else {
                    vpn.disconnect()
                }
            }
        )
    }

    private var connectToggleDisabled: Bool {
        if vpn.library.selectedProfile == nil && vpn.savedEndpoint == nil { return true }
        return vpn.busy || (vpn.isActive && !vpn.canStop)
    }

    private var modeBinding: Binding<TrafficMode> {
        Binding(
            get: { vpn.library.trafficMode },
            set: { vpn.setMode($0) }
        )
    }

    private var modeExplanation: String {
        let text: String
        switch vpn.library.trafficMode {
        case .rule:
            if (vpn.library.selectedProfile?.rules ?? []).isEmpty {
                text = "当前配置没有 IP 规则，规则模式将按全局处理。"
            } else {
                text = "按配置中的 IP-CIDR / IP-CIDR6 / MATCH 规则分流；不支持域名规则。"
            }
        case .global:
            text = "所有流量都通过当前 WireGuard 节点。"
        case .direct:
            text = "VPN 保持连接，但不接管任何流量，系统 DNS 保持不变。"
        }
        return vpn.isActive ? text + " 断开后可切换模式。" : text
    }

    @ViewBuilder private func recovery(_ issue: PrototypeVPN.Issue) -> some View {
        switch issue {
        case .permission:
            Button("打开系统设置", systemImage: "gearshape") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
        case .configuration:
            Button("前往配置", systemImage: "folder") { page = .profiles }
        case .remote:
            Button("重试连接", systemImage: "arrow.clockwise") {
                Task { await vpn.connect() }
            }
            .disabled(vpn.busy || vpn.isActive)
        case .storage:
            EmptyView()
        }
    }

    private var extensionLabel: String {
        switch vpn.extensionReady {
        case true?: "已就绪"
        case false?: "未就绪"
        case nil: "暂不可用"
        }
    }

    private static func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .binary)
    }

    private var profiles: some View {
        NavigationStack {
            Form {
                Section {
                    Button("从文件导入", systemImage: "document.badge.plus") { showingImporter = true }
                    Button("粘贴配置", systemImage: "clipboard") { showingPaste = true }
                    Button("从 URL 导入", systemImage: "link") {
                        vpn.discardImport()
                        showingURLImport = true
                    }
                    .accessibilityIdentifier("url-import")
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
                        if vpn.library.selectedProfileID != profile.id {
                            Button("设为当前") { vpn.select(profileID: profile.id) }
                                .disabled(vpn.busy || vpn.isActive)
                        }
                        if let sourceURL = profile.sourceURL {
                            LabeledContent("来源", value: sourceURL.host() ?? "链接")
                            Button {
                                Task { await vpn.update(profile) }
                            } label: {
                                if vpn.updatingProfileID == profile.id {
                                    HStack {
                                        ProgressView()
                                        Text("正在更新…")
                                    }
                                } else {
                                    Label("更新配置", systemImage: "arrow.clockwise")
                                }
                            }
                            .accessibilityIdentifier("update-profile-\(profile.name)")
                            .disabled(vpn.busy || vpn.isActive)
                        }
                        NavigationLink("兼容提示") {
                            ProfileCompatibility(profile: profile)
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
            .sheet(isPresented: $showingURLImport, onDismiss: {
                showingPreview = !vpn.imported.isEmpty
            }) {
                URLImport(vpn: vpn)
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
                        Text("支持从文件、粘贴或 HTTPS URL 导入（单次下载上限 32 KB），可保存来源链接并手动更新。节点需使用 WireGuard、IP 字面量远端、双栈客户端地址和 1–3 个隧道内 DNS 地址。")
                        Text("分流模式：全局将全部流量送入隧道；直连不接管流量并使用系统 DNS；规则模式支持 Clash rules 中的 IP-CIDR、IP-CIDR6 与 MATCH，DIRECT 走直连，其他策略名走隧道。")
                        Text("规则按顺序转换为隧道路由；不支持域名规则、GEOIP、RULE-SET、REJECT、策略组、Fake-IP、域名端点、本地监听和 YAML 别名。最多 128 条有效 IP 规则，每个 included/excluded 路由列表最多 128 个网段。")
                    }
                    .navigationTitle("配置兼容性")
                }
                NavigationLink("本地诊断") { DiagnosticsView(log: vpn.diagnostics) }
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

private struct URLImport: View {
    @Environment(\.dismiss) private var dismiss
    let vpn: PrototypeVPN
    @State private var text = ""
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://example.com/config.yaml", text: $text)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("url-field")
                } footer: {
                    Text("仅支持 HTTPS，上限 32 KB。链接保存在本机，仅用于手动更新，不会写入诊断。")
                }
                if let error {
                    Text(error).foregroundStyle(.orange)
                }
                if loading {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("正在下载…")
                    }
                }
            }
            .navigationTitle("从 URL 导入")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("下载并预览") {
                        Task {
                            loading = true
                            error = nil
                            let success = await vpn.importURL(text)
                            loading = false
                            if success {
                                dismiss()
                            } else {
                                error = vpn.importError
                            }
                        }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loading)
                    .accessibilityIdentifier("url-download")
                }
            }
        }
    }
}

private struct ImportPreview: View {
    @Environment(\.dismiss) private var dismiss
    let vpn: PrototypeVPN
    @State var selectedNode: String
    @State private var name: String

    init(vpn: PrototypeVPN, selectedNode: String) {
        self.vpn = vpn
        _selectedNode = State(initialValue: selectedNode)
        _name = State(initialValue: vpn.defaultImportName)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("配置名称", text: $name)
                if let source = vpn.stagedSourceURL {
                    LabeledContent("来源", value: source.host() ?? "链接")
                }
                if !vpn.importedRules.isEmpty {
                    LabeledContent("规则", value: "\(vpn.importedRules.count) 条")
                }
                if !vpn.importWarnings.isEmpty {
                    Section("导入提示") {
                        ForEach(vpn.importWarnings, id: \.self) { warning in
                            Text(warning).foregroundStyle(.orange)
                        }
                    }
                }
                Section("选择默认节点") {
                    Picker("节点", selection: $selectedNode) {
                        ForEach(vpn.imported) { node in
                            Text("\(node.name) · \(node.configuration.endpoint)").tag(node.id)
                        }
                    }
                    .pickerStyle(.inline)
                }
                if let node = vpn.imported.first(where: { $0.id == selectedNode }) {
                    Section("节点兼容性") {
                        LabeledContent("IPv4", value: node.configuration.clientIPv4)
                        LabeledContent("IPv6", value: node.configuration.clientIPv6)
                        LabeledContent("DNS", value: node.configuration.dnsServers.joined(separator: ", "))
                        Text("节点凭据保存在本机共享钥匙串；分流模式在连接页切换。")
                            .foregroundStyle(.secondary)
                        Text("规则模式仅使用 IP-CIDR / IP-CIDR6 / MATCH；域名、GEOIP、RULE-SET 与 REJECT 不会生效。")
                            .foregroundStyle(.secondary)
                    }
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

private struct DiagnosticsView: View {
    let log: DiagnosticLog
    @State private var showingClear = false

    var body: some View {
        List {
            if log.records.isEmpty {
                Text("暂无诊断记录。").foregroundStyle(.secondary)
            } else {
                Section {
                    ForEach(log.records.reversed()) { record in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.event)
                            Text(record.timestamp.formatted(date: .abbreviated, time: .standard))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("最近 \(log.records.count) 条")
                }
                Section {
                    ShareLink(item: log.exportText) {
                        Label("导出诊断", systemImage: "square.and.arrow.up")
                    }
                    Button("清除记录", role: .destructive) { showingClear = true }
                } footer: {
                    Text("记录保留 7 天，最多 200 条。仅含事件、错误码与时间，不含密钥、订阅链接、访问目标或包内容。")
                }
            }
        }
        .navigationTitle("本地诊断")
        .alert("清除诊断记录？", isPresented: $showingClear) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) { log.clear() }
        } message: {
            Text("将删除本机保存的全部诊断记录。")
        }
    }
}

private struct ProfileCompatibility: View {
    let profile: Profile

    var body: some View {
        List {
            ForEach(profile.nodes) { node in
                Section(node.name) {
                    LabeledContent("远端", value: node.endpoint)
                    ForEach(node.compatibilityNotes, id: \.self) { note in
                        Text(note)
                    }
                }
            }
        }
        .navigationTitle("兼容提示")
    }
}

private extension TrafficMode {
    var title: String {
        switch self {
        case .rule: "规则"
        case .global: "全局"
        case .direct: "直连"
        }
    }
}

#Preview {
    ContentView()
}
