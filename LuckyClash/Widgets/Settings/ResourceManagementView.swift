import SwiftUI

struct ResourceManagementView: View {
    let vpn: PrototypeVPN
    @State private var resources: [ClashGeodata.Status] = []
    @State private var updating = false
    @State private var message: String?

    var body: some View {
        List {
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
                    message = nil
                    Task {
                        do {
                            let yaml = try vpn.library.selectedProfile.map { try vpn.configurationText(for: $0) } ?? ""
                            try await ClashGeodata.ensure(yaml: yaml, force: true)
                            reload()
                            message = "资源更新完成。"
                        } catch { message = error.localizedDescription }
                        updating = false
                    }
                } label: {
                    if updating { ProgressView("正在更新资源…") }
                    else { Label("更新 Geo 资源", systemImage: "arrow.clockwise") }
                }
                .disabled(updating || vpn.busy || vpn.isActive)
                if let message { Text(message).font(.footnote) }
            } footer: {
                Text("使用当前配置指定的下载地址；未指定时使用默认地址。更新前请断开 VPN。每个文件单独更新；失败时该文件保留旧版本。")
            }
        }
        .navigationTitle("资源管理")
        .task { reload() }
    }

    private func reload() {
        do { resources = try ClashGeodata.status() }
        catch { message = error.localizedDescription }
    }
}
