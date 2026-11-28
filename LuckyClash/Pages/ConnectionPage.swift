import NetworkExtension
import SwiftUI
import Charts
import UIKit

struct ConnectionPage: View {
    @Environment(\.openURL) private var openURL
    @AppStorage("tunnelDisclosureVersion") private var disclosureVersion = 0
    @AppStorage("hideOutboundIP") private var hideOutboundIP = false
    @State private var showingDisclosure = false
    @State private var showingOutboundIP = false
    @State private var detection = OutboundIPDetection()
    @State private var services = ServiceAvailability()

    let vpn: PrototypeVPN
    var onImportFile: () -> Void
    var onPaste: () -> Void
    var onImportURL: () -> Void
    var onImportQR: () -> Void
    var onShowDetail: (UUID) -> Void
    var onDelete: (Profile) -> Void
    var onShowProfiles: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if vpn.library.profiles.isEmpty {
                        Button("导入配置", systemImage: "document.badge.plus") {
                            onImportFile()
                        }
                    } else {
                        ForEach(vpn.library.profiles) { profile in
                            profileRow(profile)
                        }
                    }
                } header: {
                    HStack {
                        Text("配置")
                        Spacer()
                        if !vpn.library.profiles.isEmpty {
                            Button {
                                Task { await vpn.updateAll() }
                            } label: {
                                if vpn.updatingProfileID != nil {
                                    ProgressView()
                                        .controlSize(.mini)
                                } else {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                }
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("全部更新")
                            .accessibilityIdentifier("update-all")
                            .disabled(
                                vpn.busy || vpn.switchingProfile
                                    || !vpn.library.profiles.contains { $0.sourceURL != nil }
                            )
                        }
                    }
                } footer: {
                    if vpn.library.profiles.isEmpty {
                        Text("从右上角添加配置，或点击上方按钮导入。导入并选择一个配置后才能连接。")
                    }
                }

                if vpn.library.selectedProfile != nil {
                    Section {
                        Toggle(isOn: connectionBinding) {
                            if let connectionProgress {
                                ProgressView(connectionProgress)
                                    .controlSize(.small)
                            } else {
                                Label(LocalizedStringKey(VPNStatusText.status(vpn)), systemImage: "bolt.shield")
                            }
                        }
                        .disabled(connectToggleDisabled)
                        .accessibilityIdentifier("connect-vpn")
                        if vpn.issue == .permission {
                            if let message = vpn.message {
                                Text(message)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            recovery(.permission)
                        }
                    }
                }

                if vpn.isActive, let profile = vpn.library.selectedProfile {
                    currentNodeSection(profile)
                }

                if vpn.isActive {
                    dashboardSection
                }

                serviceStatusSection
                networkDetectionSection

                if let issue = vpn.issue, issue != .storage,
                   issue != .permission || vpn.library.selectedProfile == nil {
                    Section("恢复") {
                        recovery(issue)
                    }
                }
            }
            .navigationTitle("LuckyClash")
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
                Text(AppDisclosure.text)
            }
            .sheet(isPresented: $showingOutboundIP) {
                OutboundIPDetailView(detection: detection)
            }
            .onAppear { refreshDetectionIfNeeded() }
            .onChange(of: vpn.status) { _, status in
                services.cancel()
                refreshDetection(after: status)
            }
            .onChange(of: vpn.routeRevision) { _, _ in
                services.cancel()
                guard !isRunningForPreviews else { return }
                detection.invalidate()
                if vpn.routeChangesInFlight == 0, [.connected, .disconnected].contains(vpn.status) {
                    detection.refreshForRouteChange()
                }
            }
        }
    }

    private var addProfileMenu: some View {
        Menu {
            Button {
                onImportFile()
            } label: {
                Label("从文件导入", systemImage: "document.badge.plus")
            }
            Button {
                onPaste()
            } label: {
                Label("粘贴配置", systemImage: "clipboard")
            }
            Button {
                onImportURL()
            } label: {
                Label("从 URL 导入", systemImage: "link")
            }
            Button {
                onImportQR()
            } label: {
                Label("二维码导入", systemImage: "qrcode.viewfinder")
            }
        } label: {
            Image(systemName: "plus.circle")
                .font(.title3)
                .accessibilityLabel("添加配置")
                .accessibilityIdentifier("add-profile")
        }
        .disabled(vpn.busy || vpn.switchingProfile)
    }

    private func profileRow(_ profile: Profile) -> some View {
        let selected = vpn.library.selectedProfileID == profile.id
        return Button {
            vpn.select(profileID: profile.id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .foregroundStyle(.primary)
                    Text(vpn.updatingProfileID == profile.id ? "正在更新…" : profileSubtitle(profile))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if vpn.updatingProfileID != profile.id,
                       let updated = profile.subscription?.lastUpdated {
                        Text("已更新于 \(updated.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if vpn.updatingProfileID == profile.id {
                    ProgressView()
                        .controlSize(.small)
                } else if let node = profile.selectedNode,
                   let delay = vpn.latencyValue(for: node.name, profileID: profile.id) {
                    Text("\(delay) ms")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(delayColor(delay))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!vpn.canSelectProfile)
        .accessibilityIdentifier("profile-\(profile.name)")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if profile.sourceURL != nil {
                Button {
                    Task { await vpn.update(profile) }
                } label: {
                    Label("更新", systemImage: "arrow.clockwise")
                }
                .tint(.blue)
                .disabled(!vpn.canUpdateProfile(profile.id))
            }
            Button {
                onShowDetail(profile.id)
            } label: {
                Label("详情", systemImage: "info.circle")
            }
            .tint(.indigo)
            Button(role: .destructive) {
                onDelete(profile)
            } label: {
                Label("删除", systemImage: "trash")
            }
            .disabled(!vpn.canRemoveProfile(profile.id))
        }
        .contextMenu {
            if profile.sourceURL != nil {
                Button {
                    Task { await vpn.update(profile) }
                } label: {
                    Label("更新", systemImage: "arrow.clockwise")
                }
                .disabled(!vpn.canUpdateProfile(profile.id))
            }
            Button {
                onShowDetail(profile.id)
            } label: {
                Label("详情", systemImage: "info.circle")
            }
            ProfileShareLink(profile: profile) {
                Label("分享", systemImage: "square.and.arrow.up")
            }
            Button(role: .destructive) {
                onDelete(profile)
            } label: {
                Label("删除", systemImage: "trash")
            }
            .disabled(!vpn.canRemoveProfile(profile.id))
        }
    }

    private func profileSubtitle(_ profile: Profile) -> String {
        var parts: [String] = []
        if let name = profile.selectedOutboundName {
            parts.append(name)
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
        return vpn.switchingProfile || vpn.busy || (vpn.isActive && !vpn.canStop)
    }

    private var connectionProgress: String? {
        if vpn.switchingProfile || vpn.connectionPreparation != nil || vpn.requestingConnection
            || (vpn.isActive && !vpn.canStop)
            || [.connecting, .reasserting, .disconnecting].contains(vpn.status) {
            return VPNStatusText.status(vpn)
        }
        return nil
    }

    private var modeBinding: Binding<TrafficMode> {
        Binding(
            get: { vpn.library.trafficMode },
            set: { vpn.setMode($0) }
        )
    }

    private var modeExplanation: String {
        let text = vpn.library.trafficMode.explanation
        return vpn.isActive ? text + " 连接中切换会立即应用到当前连接。" : text
    }

    private var serviceStatusSection: some View {
        Section {
            ForEach(ServiceTarget.allCases) { target in
                HStack {
                    Text(target.rawValue)
                    Spacer()
                    if let result = services.results[target] {
                        Text(serviceDescription(result))
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    } else {
                        Text(services.isChecking ? "检测中…" : "未检测")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
            }
        } header: {
            HStack {
                Text("服务状态")
                Spacer()
                Button {
                    services.refresh()
                } label: {
                    if services.isChecking { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.borderless)
                .disabled(services.isChecking || vpn.routeChangesInFlight > 0)
                .accessibilityLabel("检测服务状态")
            }
        } footer: {
            Text("检测服务连通性与可识别的地区限制。结果取决于当前路由。")
        }
    }

    private func serviceDescription(_ result: ServiceAvailabilityResult) -> String {
        let status: String
        switch result.status {
        case .reachable: status = "可连接"
        case .restricted: status = "地区或访问受限"
        case .unavailable: status = "连接失败"
        case .unknown: status = "状态待确认"
        }
        var parts = [status]
        if let region = result.region, !region.isEmpty { parts.append(region) }
        if let latency = result.latency { parts.append("\(latency) ms") }
        return parts.joined(separator: " · ")
    }

    private var dashboardSection: some View {
        Section("实时流量") {
            HStack {
                Label("下载 \(rateText(vpn.network.downloadRate))", systemImage: "arrow.down")
                Spacer()
                Label("上传 \(rateText(vpn.network.uploadRate))", systemImage: "arrow.up")
            }
            .font(.caption)
            if !vpn.network.rateHistory.isEmpty {
                Chart(vpn.network.rateHistory) { sample in
                    LineMark(x: .value("时间", sample.date), y: .value("下载", sample.download))
                        .foregroundStyle(.blue)
                    LineMark(x: .value("时间", sample.date), y: .value("上传", sample.upload))
                        .foregroundStyle(.orange)
                }
                .chartXAxis(.hidden)
                .frame(height: 100)
                .accessibilityLabel("最近一分钟的下载与上传速率")
            }
            LabeledContent("会话接收", value: VPNStatusText.bytes(vpn.network.downloadTotal))
            LabeledContent("会话发送", value: VPNStatusText.bytes(vpn.network.uploadTotal))
            HStack {
                LabeledContent("内核内存", value: vpn.network.memoryFootprint.map { VPNStatusText.bytes($0) } ?? "暂不可用")
                Button("释放") { vpn.freeTunnelMemory() }
                    .buttonStyle(.borderless)
                    .disabled(vpn.status != .connected)
            }
        }
    }

    private func rateText(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .binary) + "/s"
    }

    @ViewBuilder private func currentNodeSection(_ profile: Profile) -> some View {
        Section {
            Picker("分流模式", selection: modeBinding) {
                                ForEach(TrafficMode.allCases, id: \.self) { mode in
                                    Text(LocalizedStringKey(mode.title)).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .disabled(vpn.busy || vpn.switchingProfile)
                            .accessibilityIdentifier("mode-picker")
            Button {
                guard vpn.canSwitchNodes(for: profile.id) else { return }
                onShowProfiles()
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(currentStrategyText(profile))
                            .foregroundStyle(.primary)
                        Text(nodeSubtitle(profile))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if let node = profile.selectedNode {
                        LatencyBadge(
                            state: vpn.latencyState(for: node.name, profileID: profile.id)
                        )
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("current-node")
            .contextMenu { currentNodeLatencyAction(profile) }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                currentNodeLatencyAction(profile)
            }
        } header: {
            Text("当前节点")
        }
    }

    private func currentStrategyText(_ profile: Profile) -> String {
        if vpn.library.trafficMode == .direct { return "直连" }
        if let root = vpn.library.trafficMode == .global ? "GLOBAL" : profile.clashGroup {
            let chain = vpn.strategyChain(from: root, profile: profile)
            if chain.count > 1 { return chain.joined(separator: " → ") }
        }
        return profile.selectedOutboundName ?? "未选择节点"
    }

    @ViewBuilder private func currentNodeLatencyAction(_ profile: Profile) -> some View {
        if let node = profile.selectedNode, node.type != "auto" {
            Button {
                Task { await vpn.testLatency(nodeNames: [node.name]) }
            } label: {
                Label("测试延迟", systemImage: "speedometer")
            }
            .disabled(vpn.busy || vpn.latencyTesting)
        }
    }

    // MARK: - Network detection

    @ViewBuilder private var networkDetectionSection: some View {
        Section {
            if let report = detection.report {
                Button {
                    showingOutboundIP = true
                } label: {
                    detectionRow(report)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("network-detection")

                if let failure = detection.failure {
                    Text("上次检测失败：\(failure.localizedDescription)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else if let failure = detection.failure {
                VStack(alignment: .leading, spacing: 6) {
                    Label("检测失败", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(failure.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("重新检测") { detection.refresh() }
                        .font(.callout)
                        .disabled(detection.isChecking || vpn.routeChangesInFlight > 0)
                }
            } else {
                HStack(spacing: 8) {
                    if detection.isChecking {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Text(detection.isChecking ? "正在检测出口 IP…" : "尚未检测")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            HStack {
                Text("网络检测")
                Spacer()
                Button {
                    detection.refresh()
                } label: {
                    if detection.isChecking {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(detection.isChecking || vpn.routeChangesInFlight > 0)
                .accessibilityLabel("重新检测出口 IP")
                .accessibilityIdentifier("refresh-network-detection")
            }
        }
    }

    private func detectionRow(_ report: OutboundIPReport) -> some View {
        HStack(spacing: 12) {
            Text(report.countryCode ?? "—")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 26)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityLabel(report.countryName.isEmpty ? "未知地区" : report.countryName)
            VStack(alignment: .leading, spacing: 3) {
                Text(hideOutboundIP ? "••••••••" : report.ip)
                    .font(.callout.monospaced())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.7)
                Text(detectionSubtitle(report))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                (Text("质量") + Text(" ") + Text(LocalizedStringKey(report.quality.title)))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(detectionColor(report.quality))
                Text(LocalizedStringKey(report.kind.title))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func detectionSubtitle(_ report: OutboundIPReport) -> String {
        var parts: [String] = []
        if !report.countryName.isEmpty { parts.append(report.countryName) }
        if let organization = report.organization, !organization.isEmpty {
            parts.append(organization)
        }
        if !report.flags.isEmpty { parts.append(report.flags.joined(separator: "/")) }
        if parts.isEmpty { parts.append("第三方查询") }
        return parts.joined(separator: " · ")
    }

    private func detectionColor(_ quality: OutboundIPReport.Quality) -> Color {
        switch quality {
        case .good: .green
        case .normal: .secondary
        case .risky: .red
        }
    }

    private var networkDetectionFooter: String {
        let origin = vpn.isActive
            ? "检测经当前 VPN 路由发起，反映当前流量出口。"
            : "未连接 VPN，检测反映当前普通网络出口。"
        return origin + "由第三方 IP 查询服务提供，结果仅供参考，且只保留在内存中。"
    }

    private func refreshDetectionIfNeeded() {
        guard !isRunningForPreviews, vpn.routeChangesInFlight == 0 else { return }
        detection.refreshIfStale()
    }

    private func refreshDetection(after status: NEVPNStatus) {
        guard !isRunningForPreviews else { return }
        detection.invalidate()
        if vpn.routeChangesInFlight == 0, [.connected, .disconnected].contains(status) {
            detection.refreshForRouteChange()
        }
    }

    private var isRunningForPreviews: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    private func nodeSubtitle(_ profile: Profile) -> String {
        var parts: [String] = []
        if profile.clashSelectedMember == nil, let type = profile.selectedNode?.type, !type.isEmpty {
            parts.append(type)
        }
        if let group = profile.clashGroup, !group.isEmpty {
            parts.append(group)
        }
        if parts.isEmpty {
            parts.append("轻点切换节点")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func recovery(_ issue: PrototypeVPN.Issue) -> some View {
        switch issue {
        case .permission:
            Button("打开系统设置", systemImage: "gearshape") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
        case .configuration:
            Button("前往配置", systemImage: "folder") { onShowProfiles() }
        case .remote:
            Button("重试连接", systemImage: "arrow.clockwise") {
                Task { await vpn.connect() }
            }
            .disabled(vpn.busy || vpn.isActive)
        case .storage:
            EmptyView()
        }
    }
}

enum AppDisclosure {
    static let text = "LuckyClash 将配置和凭据保存在本机。纳入系统 VPN 路由的 IP 流量和 DNS 请求由你选择的远端转发。远端地址和 iOS 系统例外可走普通网络。断开后，iOS 可能恢复普通网络访问。网络页的连接与日志只保留在内存中。LuckyClash 不上传配置、流量或诊断。"
}
