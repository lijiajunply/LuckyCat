import NetworkExtension
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    enum Page: Hashable { case connection, network, profiles, settings }

    @Environment(\.scenePhase) private var scenePhase
    @State private var vpn: PrototypeVPN
    @State private var page: Page
    @State private var showingImporter = false
    @State private var showingPaste = false
    @State private var showingURLImport = false
    @State private var showingQRImport = false
    @State private var pendingQRPayload: String?
    @State private var pendingImportName = ""
    @State private var showingPreview = false
    @State private var pendingDeletion: Profile?
    @State private var detailProfileID: UUID?
    @State private var showingInfo = false

    /// The defaults keep the app entry point unchanged (`ContentView()`); the
    /// parameters exist so previews can open a specific page with seeded state.
    init(vpn: PrototypeVPN = PrototypeVPN(), page: Page = .connection) {
        _vpn = State(initialValue: vpn)
        _page = State(initialValue: page)
    }

    var body: some View {
        TabView(selection: $page) {
            ConnectionPage(
                vpn: vpn,
                onImportFile: {
                    pendingImportName = ""
                    showingImporter = true
                },
                onPaste: {
                    pendingImportName = ""
                    showingPaste = true
                },
                onImportURL: {
                    pendingImportName = ""
                    vpn.discardImport()
                    showingURLImport = true
                },
                onImportQR: {
                    pendingImportName = ""
                    showingQRImport = true
                },
                onShowDetail: { detailProfileID = $0 },
                onDelete: { pendingDeletion = $0 },
                onShowProfiles: { page = .profiles }
            )
            .tabItem { Label("连接", systemImage: "bolt.shield") }
            .tag(Page.connection)
            ProfilesView(
                vpn: vpn,
                onShowDetail: { detailProfileID = $0 },
                onDelete: { pendingDeletion = $0 },
                onShowConnection: { page = .connection },
                onShowInfo: { showingInfo = true }
            )
            .tabItem { Label("配置", systemImage: "folder") }
            .tag(Page.profiles)
            NetworkPage(vpn: vpn)
                .tabItem { Label("网络", systemImage: "waveform.path.ecg") }
                .tag(Page.network)
            SettingsPage(vpn: vpn)
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(Page.settings)
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.yaml, .json, .plainText]) { result in
            switch result {
            case .success(let url):
                vpn.importFile(url)
                showingPreview = vpn.hasStagedImport
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError {
                    vpn.message = "无法打开配置文件。"
                }
            }
        }
        .sheet(isPresented: $showingPaste, onDismiss: presentStagedPreview) {
            PasteConfiguration(name: $pendingImportName) { text in
                vpn.stage(Data(text.utf8))
                return vpn.imported.isEmpty ? vpn.importError : nil
            }
        }
        .sheet(isPresented: $showingURLImport, onDismiss: presentStagedPreview) {
            URLImport(vpn: vpn, name: $pendingImportName)
        }
        .sheet(isPresented: $showingQRImport, onDismiss: importQRCode) {
            QRCodeImportView { code in
                pendingQRPayload = code
                showingQRImport = false
            }
        }
        .sheet(isPresented: $showingPreview, onDismiss: vpn.discardImport) {
            if let first = vpn.imported.first {
                ImportPreview(vpn: vpn, selectedNode: first.id, initialName: pendingImportName)
            } else {
                ImportPreview(vpn: vpn, selectedNode: "", initialName: pendingImportName)
            }
        }
        .sheet(isPresented: Binding(
            get: { detailProfileID != nil },
            set: { if !$0 { detailProfileID = nil } }
        )) {
            if let detailProfileID {
                ProfileDetailView(vpn: vpn, profileID: detailProfileID)
            }
        }
        .sheet(isPresented: $showingInfo) {
            ConnectionInfoView(vpn: vpn)
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
        .task {
            await vpn.refresh()
            await vpn.updateDueProfiles()
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                Task {
                    await vpn.refresh()
                    await vpn.updateDueProfiles()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NEVPNStatusDidChange)) { _ in
            Task { await vpn.updateStatus() }
        }
        .onOpenURL { url in
            handleOpenURL(url)
        }
    }

    /// Supports `clash://install-config?url=<subscription>` and
    /// `luckyclash://install-config?url=<subscription>` like FlClash.
    private func handleOpenURL(_ url: URL) {
        guard ["clash", "luckyclash"].contains(url.scheme?.lowercased() ?? "") else { return }
        let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "url" })?.value
        guard let target, RemoteImport.url(from: target) != nil else { return }
        page = .profiles
        pendingImportName = ""
        vpn.discardImport()
        Task {
            if await vpn.importURL(target) {
                showingPreview = true
            }
        }
    }

    /// Opens the import preview once the source sheet has finished
    /// dismissing; presenting a second sheet during dismissal is unreliable.
    private func presentStagedPreview() {
        guard vpn.hasStagedImport else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            showingPreview = true
        }
    }

    private func importQRCode() {
        guard let payload = pendingQRPayload else { return }
        pendingQRPayload = nil
        pendingImportName = ""
        vpn.discardImport()
        if let url = QRCodePayload.subscriptionURL(from: payload) {
            Task {
                if await vpn.importURL(url.absoluteString) {
                    try? await Task.sleep(for: .milliseconds(250))
                    showingPreview = true
                } else {
                    vpn.message = vpn.importError
                }
            }
        } else {
            // Share links, a raw Clash YAML, or a base64 subscription bundle.
            vpn.stage(Data(payload.utf8))
            if vpn.hasStagedImport {
                showingPreview = true
            } else {
                vpn.message = vpn.importError ?? "二维码内容不是有效的配置链接。"
            }
        }
    }

}

enum ImportSummary {
    static func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .binary)
    }

    static func flow(_ subscription: Profile.Subscription) -> String {
        let down = bytes(subscription.download ?? 0)
        let up = bytes(subscription.upload ?? 0)
        guard let total = subscription.total, total > 0 else {
            return "↓ \(down) · ↑ \(up)"
        }
        let used = (subscription.download ?? 0) + (subscription.upload ?? 0)
        return "↓ \(down) · ↑ \(up) · \(bytes(used)) / \(bytes(total))"
    }

    static func expiry(_ date: Date?) -> String {
        guard let date else { return "长期" }
        return date < Date()
            ? "已到期"
            : date.formatted(date: .abbreviated, time: .omitted)
    }
}

struct MessageLabel: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.circle")
            .foregroundStyle(.orange)
            .font(.footnote)
    }
}

private struct PasteConfiguration: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var name: String
    @State private var text = ""
    @State private var error: String?
    let parse: (String) -> String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("配置名称（可选）", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("paste-name")
                } footer: {
                    Text("留空时使用默认名称。")
                }
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
    @Binding var name: String
    @State private var text = ""
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("配置名称（可选）", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("url-name")
                } footer: {
                    Text("留空时使用默认名称。")
                }
                Section {
                    TextField("https://example.com/config.yaml", text: $text)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("url-field")
                } footer: {
                    Text("仅支持 HTTPS，上限 8 MB。支持 Clash YAML、base64 订阅和分享链接；链接保存在本机用于手动或自动更新，不会写入诊断。")
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

    init(vpn: PrototypeVPN, selectedNode: String, initialName: String = "") {
        self.vpn = vpn
        _selectedNode = State(initialValue: selectedNode)
        _name = State(initialValue: initialName)
    }

    /// The default name used when the name field is left empty.
    private var resolvedName: String {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed.isEmpty else { return String(typed.prefix(80)) }
        let suggested = vpn.defaultImportName
        if !suggested.isEmpty { return suggested }
        return selectedNode.isEmpty
            ? (vpn.stagedEngine == .clash ? "Clash 配置" : "配置")
            : selectedNode
    }

    private var namePlaceholder: String {
        let suggested = vpn.defaultImportName
        return suggested.isEmpty
            ? "配置名称（留空使用默认名称）"
            : "配置名称（留空使用「\(suggested)」）"
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(namePlaceholder, text: $name)
                    .accessibilityIdentifier("import-name")
                if let source = vpn.stagedSourceURL {
                    LabeledContent("来源", value: source.host() ?? "链接")
                }
                LabeledContent("类型", value: vpn.stagedEngine == .clash ? "Clash" : "WireGuard")
                if let subscription = vpn.stagedSubscription {
                    LabeledContent(
                        "流量",
                        value: ImportSummary.flow(subscription)
                    )
                    LabeledContent("到期", value: ImportSummary.expiry(subscription.expire))
                }
                if !vpn.stagedGroups.isEmpty {
                    LabeledContent("策略组", value: "\(vpn.stagedGroups.count) 个")
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
                if vpn.imported.isEmpty {
                    Section("节点") {
                        Text("节点由配置中的 proxy-providers 提供，连接时由内核加载。")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("选择默认节点") {
                        Picker("节点", selection: $selectedNode) {
                            ForEach(vpn.imported) { node in
                                Text(node.endpoint.isEmpty
                                    ? "\(node.name) · \(node.type)"
                                    : "\(node.name) · \(node.type) · \(node.endpoint)")
                                    .tag(node.id)
                            }
                        }
                        .pickerStyle(.inline)
                    }
                }
                if let node = vpn.imported.first(where: { $0.id == selectedNode }) {
                    Section("节点兼容性") {
                        LabeledContent("协议", value: node.type)
                        if let configuration = node.configuration {
                            LabeledContent("IPv4", value: configuration.clientIPv4)
                            LabeledContent("IPv6", value: configuration.clientIPv6)
                            LabeledContent("DNS", value: configuration.dnsServers.joined(separator: ", "))
                            Text("旧版 WireGuard 参数会转换为 Clash 配置，由内核在隧道内执行。")
                                .foregroundStyle(.secondary)
                        } else {
                            if !node.endpoint.isEmpty {
                                LabeledContent("远端", value: node.endpoint)
                            }
                            Text("由 Clash 内核按配置中的代理组和规则分流，支持 ss / vmess / vless / trojan / hysteria2 / tuic / wireguard 等节点。")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let error = vpn.importError { Text(error).foregroundStyle(.orange) }
            }
            .navigationTitle("导入预览")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if vpn.saveImport(named: resolvedName, selectedNode: selectedNode) {
                            dismiss()
                        }
                    }
                    .disabled(vpn.imported.isEmpty && vpn.stagedEngine != .clash)
                }
            }
        }
    }
}

#if DEBUG
// MARK: - Pages

#Preview("连接 · 已连接") {
    ContentView(
        vpn: .preview(
            status: .connected,
            traffic: PrototypeVPN.Traffic(
                received: 8_264_192, sent: 1_284_096, updatedAt: .now
            ),
            extensionReady: true,
            latencyResults: PreviewSamples.latencyResults(forProfile: PreviewSamples.profileID)
        ),
        page: .connection
    )
}

#Preview("连接 · 已断开") {
    ContentView(vpn: .preview(), page: .connection)
}

#Preview("连接 · 连接中") {
    ContentView(vpn: .preview(status: .connecting), page: .connection)
}

#Preview("连接 · 未配置") {
    ContentView(vpn: .preview(library: ProfileLibrary()), page: .connection)
}

#Preview("网络") {
    ContentView(vpn: .previewNetwork(), page: .network)
}

#Preview("配置") {
    ContentView(
        vpn: .preview(
            latencyResults: PreviewSamples.latencyResults(forProfile: PreviewSamples.profileID)
        ),
        page: .profiles
    )
}

#Preview("设置") {
    ContentView(vpn: .preview(), page: .settings)
}

// MARK: - Sheets

#Preview("粘贴配置") {
    PasteConfiguration(name: .constant("")) { _ in nil }
}

#Preview("从 URL 导入") {
    URLImport(vpn: .preview(), name: .constant(""))
}

#Preview("导入预览") {
    ImportPreview(
        vpn: .previewStaged(),
        selectedNode: PreviewSamples.importedNodes[0].id
    )
}

#Preview("提示文字") {
    List {
        MessageLabel(text: "iOS 未启动连接，请检查系统 VPN 设置。")
        MessageLabel(text: "正在准备 GeoIP 数据…")
    }
}
#endif
