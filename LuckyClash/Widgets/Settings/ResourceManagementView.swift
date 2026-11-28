import SwiftUI

struct ResourceManagementView: View {
    let vpn: PrototypeVPN
    @AppStorage("closeConnectionsOnNodeSwitch") private var closeConnectionsOnNodeSwitch = true
    @AppStorage("latencyTestURL") private var latencyTestURL = ClashLatencyTester.defaultTestURL
    @AppStorage(ClashGeodata.geoIPSourceKey) private var geoIPSource = ""
    @AppStorage(ClashGeodata.geoSiteSourceKey) private var geoSiteSource = ""
    @AppStorage(ClashGeodata.updateIntervalKey) private var updateInterval = 0
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
                Picker("自动更新", selection: $updateInterval) {
                    Text("仅手动").tag(0)
                    Text("每天").tag(1)
                    Text("每周").tag(7)
                    Text("每月").tag(30)
                }
                TextField("自定义 GeoIP HTTPS 地址", text: $geoIPSource)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("自定义 GeoSite HTTPS 地址", text: $geoSiteSource)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
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
                Text("自定义地址优先于配置中的地址。自动更新在连接前检查，更新失败时保留旧文件。")
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
