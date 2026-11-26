import SwiftUI

struct SettingsPage: View {
    let vpn: PrototypeVPN
    let onShowProfile: (UUID) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("配置与资源") {
                    NavigationLink {
                        SubscriptionManagementView(vpn: vpn, onShowDetail: onShowProfile)
                    } label: {
                        Label("订阅管理", systemImage: "arrow.clockwise")
                    }
                    NavigationLink {
                        ResourceManagementView(vpn: vpn)
                    } label: {
                        Label("资源管理", systemImage: "externaldrive")
                    }
                }

                Section("帮助与隐私") {
                    NavigationLink {
                        compatibilityDetails
                    } label: {
                        Label("配置兼容性", systemImage: "doc.text")
                    }
                    NavigationLink {
                        DiagnosticsView(log: vpn.diagnostics)
                    } label: {
                        Label("本地诊断", systemImage: "stethoscope")
                    }
                    NavigationLink {
                        List { Text(AppDisclosure.text) }
                            .navigationTitle("隐私与数据使用")
                    } label: {
                        Label("隐私与数据使用", systemImage: "hand.raised")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("设置")
        }
    }

    private var compatibilityDetails: some View {
        List {
            Text("支持从文件、粘贴、HTTPS URL 或二维码导入（单次上限 8 MB），可保存来源链接、显示订阅流量与到期时间，并按配置的更新间隔自动更新。URL 可指向 Clash YAML、base64 订阅或分享链接。")
            Text("导入的配置由固定版本的 Clash 内核在隧道内执行，支持 ss、ssr、vmess、vless、trojan、hysteria、hysteria2、tuic、wireguard、socks、http 等协议，以及策略组、域名规则、GEOIP、RULE-SET 与 Fake-IP。")
            Text("延迟测试在连接时通过正在运行的内核执行；断开时会在本机临时启动一个只用于测速的 Clash 内核，移除配置中的监听端口与规则，不会建立 VPN 隧道，也不会上传测试结果。")
            Text("网络页通过本机控制通道显示内核正在处理的连接与日志，连接中可直接切换分流模式和当前配置的节点。这些数据只保存在内存中，不会写入诊断、持久化或上传。")
            Text("连接页的网络检测会向第三方 IP 查询服务发送当前出口 IP，仅用于显示归属地、类型与质量；查询结果只保留在内存中，不写入诊断，也不会保存。")
            Text("旧版 WireGuard YAML / JSON 配置仍可导入，会自动转换为 Clash WireGuard 节点；已有旧配置会在下次刷新或连接时迁移。")
            Text("自动更新仅在你打开 App 或手动触发时运行，不会在后台定时联网。订阅链接与配置内容不会写入诊断。")
        }
        .navigationTitle("配置兼容性")
    }
}
