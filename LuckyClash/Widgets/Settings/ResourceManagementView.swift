import SwiftUI

struct ResourceManagementView: View {
    let vpn: PrototypeVPN
    @AppStorage("closeConnectionsOnNodeSwitch") private var closeConnectionsOnNodeSwitch = true
    @AppStorage("latencyTestURL") private var latencyTestURL = ClashLatencyTester.defaultTestURL
    @State private var resources: [ClashGeodata.Status] = []
    @State private var updating = false

    var body: some View {
        List {
            Section {
                Toggle("切换节点时关闭已有连接", isOn: $closeConnectionsOnNodeSwitch)

                VStack(alignment: .leading, spacing: 6) {
                    Text("延迟测试链接")
                    TextField("默认测试链接", text: $latencyTestURL)
                        .font(.subheadline)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel(Text("延迟测试链接"))
                }
            } header: {
                Text("连接与测速")
            } footer: {
                Text("策略组配置了测试链接时，优先使用策略组的链接。")
            }

            Section {
                ForEach(resources) { resource in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(resource.name)
                        if let size = resource.size, let modified = resource.modified {
                            Text("\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) · \(modified.formatted(date: .abbreviated, time: .shortened))")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Text("尚未下载").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                Button {
                    updating = true
                    Task {
                        defer { updating = false }
                        do {
                            let yaml = try vpn.library.selectedProfile.map { try vpn.configurationText(for: $0) } ?? ""
                            try await ClashGeodata.ensure(yaml: yaml, force: true)
                            resources = try ClashGeodata.status()
                            vpn.showToast("资源已更新", isSuccess: true)
                        } catch { vpn.showToast(error.localizedDescription) }
                    }
                } label: {
                    if updating { ProgressView("正在更新资源…") }
                    else { Label("更新 Geo 资源", systemImage: "arrow.clockwise") }
                }
                .disabled(updating || vpn.busy || vpn.isActive)
            } footer: {
                Text("使用当前配置指定的下载地址；未指定时使用默认地址。更新前请断开 VPN。每个文件单独更新；失败时该文件保留旧版本。")
            }
        }
        .navigationTitle("资源管理")
        .task { reload() }
    }

    private func reload() {
        do { resources = try ClashGeodata.status() }
        catch { vpn.showToast(error.localizedDescription) }
    }
}
