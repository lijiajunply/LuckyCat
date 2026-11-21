import NetworkExtension
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    enum Page: Hashable { case connection, profiles, settings }

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @AppStorage("tunnelDisclosureVersion") private var disclosureVersion = 0
    @State private var vpn = PrototypeVPN()
    @State private var page = Page.connection
    @State private var showingImporter = false
    @State private var showingPaste = false
    @State private var showingURLImport = false
    @State private var showingQRImport = false
    @State private var pendingQRPayload: String?
    @State private var showingPreview = false
    @State private var showingDisclosure = false
    @State private var pendingDeletion: Profile?
    @State private var detailProfileID: UUID?

    private static let disclosure = "LuckyCat 将配置和凭据保存在本机。纳入系统 VPN 路由的 IP 流量和 DNS 请求由你选择的远端转发。远端地址和 iOS 系统例外可走普通网络。断开后，iOS 可能恢复普通网络访问。LuckyCat 不上传配置、流量或诊断。"

    var body: some View {
        TabView(selection: $page) {
            connection.tabItem { Label("连接", systemImage: "bolt.shield") }.tag(Page.connection)
            ProfilesView(
                vpn: vpn,
                onImportFile: { showingImporter = true },
                onPaste: { showingPaste = true },
                onImportURL: {
                    vpn.discardImport()
                    showingURLImport = true
                },
                onImportQR: { showingQRImport = true },
                onShowDetail: { detailProfileID = $0 },
                onDelete: { pendingDeletion = $0 },
                onShowConnection: { page = .connection }
            )
            .tabItem { Label("配置", systemImage: "folder") }
            .tag(Page.profiles)
            settings.tabItem { Label("设置", systemImage: "gearshape") }.tag(Page.settings)
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
        .sheet(isPresented: $showingPaste, onDismiss: {
            showingPreview = vpn.hasStagedImport
        }) {
            PasteConfiguration { text in
                vpn.stage(Data(text.utf8))
                return vpn.imported.isEmpty ? vpn.importError : nil
            }
        }
        .sheet(isPresented: $showingURLImport, onDismiss: {
            showingPreview = vpn.hasStagedImport
        }) {
            URLImport(vpn: vpn)
        }
        .sheet(isPresented: $showingQRImport, onDismiss: importQRCode) {
            QRCodeImportView { code in
                pendingQRPayload = code
                showingQRImport = false
            }
        }
        .sheet(isPresented: $showingPreview, onDismiss: vpn.discardImport) {
            if let first = vpn.imported.first {
                ImportPreview(vpn: vpn, selectedNode: first.id)
            } else {
                ImportPreview(vpn: vpn, selectedNode: "")
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
    /// `luckycat://install-config?url=<subscription>` like FlClash.
    private func handleOpenURL(_ url: URL) {
        guard ["clash", "luckycat"].contains(url.scheme?.lowercased() ?? "") else { return }
        let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "url" })?.value
        guard let target, RemoteImport.url(from: target) != nil else { return }
        page = .profiles
        vpn.discardImport()
        Task {
            if await vpn.importURL(target) {
                showingPreview = true
            }
        }
    }

    private func importQRCode() {
        guard let payload = pendingQRPayload else { return }
        pendingQRPayload = nil
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

    private var connection: some View {
        NavigationStack {
            List {
                Section("VPN") {
                    LabeledContent("状态", value: statusLabel)
                    if let profile = vpn.library.selectedProfile, let node = profile.selectedNode {
                        LabeledContent("配置", value: profile.name)
                        LabeledContent("节点", value: node.name)
                        if let group = profile.clashGroup, !group.isEmpty {
                            LabeledContent("策略组", value: group)
                        }
                        if !node.endpoint.isEmpty {
                            LabeledContent("远端", value: node.endpoint)
                        }
                    }
                    if vpn.isActive {
                        LabeledContent("扩展", value: extensionLabel)
                    }
                    feedback
                }

                Section {
                    if vpn.library.profiles.isEmpty {
                        Button("导入配置", systemImage: "document.badge.plus") {
                            showingImporter = true
                        }
                    } else {
                        ForEach(vpn.library.profiles) { profile in
                            profileRow(profile)
                        }
                    }
                } header: {
                    Text("配置")
                } footer: {
                    if vpn.library.profiles.isEmpty {
                        Text("从右上角添加配置，或点击上方按钮导入。导入并选择一个配置后才能连接。")
                    } else {
                        Text("点击选择配置；右滑或长按可查看详情或删除。")
                    }
                }

                if vpn.library.selectedProfile != nil {
                    Section {
                        Toggle(isOn: connectionBinding) {
                            Label("连接", systemImage: "bolt.shield")
                        }
                        .disabled(connectToggleDisabled)
                        .accessibilityIdentifier("connect-vpn")
                    } footer: {
                        if vpn.isActive {
                            Text("断开后，iOS 可能恢复普通网络访问。")
                        } else {
                            Text("首次连接前会说明数据使用方式。")
                        }
                    }
                }

                if vpn.library.selectedProfile?.resolvedEngine == .clash {
                    Section {
                        LabeledContent("分流", value: "由 Clash 配置决定")
                    } header: {
                        Text("分流模式")
                    } footer: {
                        Text("代理组与规则由导入的 Clash 配置在隧道内执行。")
                    }
                } else {
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    addProfileMenu
                }
            }
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

    private var addProfileMenu: some View {
        Menu {
            Button {
                showingImporter = true
            } label: {
                Label("从文件导入", systemImage: "document.badge.plus")
            }
            Button {
                showingPaste = true
            } label: {
                Label("粘贴配置", systemImage: "clipboard")
            }
            Button {
                vpn.discardImport()
                showingURLImport = true
            } label: {
                Label("从 URL 导入", systemImage: "link")
            }
            Button {
                showingQRImport = true
            } label: {
                Label("二维码导入", systemImage: "qrcode.viewfinder")
            }
        } label: {
            Image(systemName: "plus.circle")
                .font(.title3)
                .accessibilityLabel("添加配置")
                .accessibilityIdentifier("add-profile")
        }
        .disabled(vpn.busy || vpn.isActive)
    }

    private func profileRow(_ profile: Profile) -> some View {
        let selected = vpn.library.selectedProfileID == profile.id
        return Button {
            guard !vpn.busy, !vpn.isActive else { return }
            vpn.select(profileID: profile.id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .foregroundStyle(.primary)
                    Text(profileSubtitle(profile))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let node = profile.selectedNode,
                   let delay = vpn.latencyValue(for: node.name, profileID: profile.id) {
                    Text("\(delay) ms")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(delayColor(delay))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("profile-\(profile.name)")
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                detailProfileID = profile.id
            } label: {
                Label("详情", systemImage: "info.circle")
            }
            .tint(.blue)
            Button(role: .destructive) {
                pendingDeletion = profile
            } label: {
                Label("删除", systemImage: "trash")
            }
            .disabled(vpn.busy || vpn.isActive)
        }
        .contextMenu {
            Button {
                detailProfileID = profile.id
            } label: {
                Label("详情", systemImage: "info.circle")
            }
            Button(role: .destructive) {
                pendingDeletion = profile
            } label: {
                Label("删除", systemImage: "trash")
            }
            .disabled(vpn.busy || vpn.isActive)
        }
    }

    private func profileSubtitle(_ profile: Profile) -> String {
        var parts: [String] = []
        if let node = profile.selectedNode {
            parts.append(node.name)
        }
        if let group = profile.clashGroup, !group.isEmpty {
            parts.append(group)
        }
        if let host = profile.sourceURL?.host() {
            parts.append(host)
        } else {
            parts.append("本地配置")
        }
        return parts.joined(separator: " · ")
    }

    private func delayColor(_ delay: Int) -> Color {
        switch delay {
        case ..<100: .green
        case ..<250: .orange
        default: .red
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
        if vpn.library.selectedProfile == nil { return true }
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

    private var settings: some View {
        NavigationStack {
            List {
                NavigationLink("隐私与数据使用") {
                    List { Text(Self.disclosure) }
                        .navigationTitle("隐私与数据使用")
                }
                NavigationLink("配置兼容性") {
                    List {
                        Text("支持从文件、粘贴、HTTPS URL 或二维码导入（单次上限 8 MB），可保存来源链接、显示订阅流量与到期时间，并按配置的更新间隔自动更新。URL 可指向 Clash YAML、base64 订阅或分享链接。")
                        Text("导入的配置由固定版本的 Clash 内核在隧道内执行，支持 ss、ssr、vmess、vless、trojan、hysteria、hysteria2、tuic、wireguard、socks、http 等协议，以及策略组、域名规则、GEOIP、RULE-SET 与 Fake-IP。")
                        Text("延迟测试会在本机临时启动一个只用于测速的 Clash 内核，移除配置中的监听端口与规则，不会建立 VPN 隧道，也不会上传测试结果。")
                        Text("旧版 WireGuard YAML / JSON 配置仍可导入，会自动转换为 Clash WireGuard 节点；已有旧配置会在下次刷新或连接时迁移。")
                        Text("自动更新仅在你打开 App 或手动触发时运行，不会在后台定时联网。订阅链接与配置内容不会写入诊断。")
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
            MessageLabel(text: message)
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
                        let title = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
                        let fallback = selectedNode.isEmpty
                            ? (vpn.stagedEngine == .clash ? "Clash 配置" : "配置")
                            : selectedNode
                        if vpn.saveImport(named: title.isEmpty ? fallback : title, selectedNode: selectedNode) {
                            dismiss()
                        }
                    }
                    .disabled(vpn.imported.isEmpty && vpn.stagedEngine != .clash)
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
