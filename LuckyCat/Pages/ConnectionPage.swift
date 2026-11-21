import SwiftUI
import UIKit

struct ConnectionPage: View {
    @Environment(\.openURL) private var openURL
    @AppStorage("tunnelDisclosureVersion") private var disclosureVersion = 0
    @State private var showingDisclosure = false

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
                                vpn.busy || vpn.isActive
                                    || !vpn.library.profiles.contains { $0.sourceURL != nil }
                            )
                        }
                    }
                } footer: {
                    if vpn.library.profiles.isEmpty {
                        Text("从右上角添加配置，或点击上方按钮导入。导入并选择一个配置后才能连接。")
                    } else {
                        Text("点击选择配置；右滑或长按可更新、编辑或删除。")
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
                Text(AppDisclosure.text)
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
            if profile.sourceURL != nil {
                Button {
                    Task { await vpn.update(profile) }
                } label: {
                    Label("更新", systemImage: "arrow.clockwise")
                }
                .tint(.blue)
                .disabled(vpn.busy || vpn.isActive)
            }
            Button {
                onShowDetail(profile.id)
            } label: {
                Label("编辑", systemImage: "square.and.pencil")
            }
            .tint(.indigo)
            Button(role: .destructive) {
                onDelete(profile)
            } label: {
                Label("删除", systemImage: "trash")
            }
            .disabled(vpn.busy || vpn.isActive)
        }
        .contextMenu {
            if profile.sourceURL != nil {
                Button {
                    Task { await vpn.update(profile) }
                } label: {
                    Label("更新", systemImage: "arrow.clockwise")
                }
                .disabled(vpn.busy || vpn.isActive)
            }
            Button {
                onShowDetail(profile.id)
            } label: {
                Label("编辑", systemImage: "square.and.pencil")
            }
            Button(role: .destructive) {
                onDelete(profile)
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
        let text = vpn.library.trafficMode.explanation
        return vpn.isActive ? text + " 断开后可切换模式。" : text
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
    static let text = "LuckyCat 将配置和凭据保存在本机。纳入系统 VPN 路由的 IP 流量和 DNS 请求由你选择的远端转发。远端地址和 iOS 系统例外可走普通网络。断开后，iOS 可能恢复普通网络访问。LuckyCat 不上传配置、流量或诊断。"
}
