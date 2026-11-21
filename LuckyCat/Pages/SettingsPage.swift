import SwiftUI

struct SettingsPage: View {
    let vpn: PrototypeVPN

    var body: some View {
        NavigationStack {
            List {
                NavigationLink("隐私与数据使用") {
                    List { Text(AppDisclosure.text) }
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

#if DEBUG
#Preview("本地诊断") {
    NavigationStack {
        DiagnosticsView(log: PreviewSamples.diagnosticLog())
    }
}
#endif
