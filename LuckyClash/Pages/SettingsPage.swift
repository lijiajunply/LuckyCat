import SwiftUI
import NetworkExtension

struct SettingsPage: View {
    let vpn: PrototypeVPN
    let onShowProfile: (UUID) -> Void
    @AppStorage(ClashDelayRequest.timeoutKey) private var delayTimeout = ClashDelayRequest.defaultTimeout

    var body: some View {
        NavigationStack {
            List {
                Section("配置与资源") {
                    NavigationLink {
                        CustomProfileBuilderView(vpn: vpn)
                    } label: {
                        Label("自定义配置", systemImage: "slider.horizontal.3")
                    }
                    NavigationLink {
                        BackupRestoreView(vpn: vpn)
                    } label: {
                        Label("备份与恢复", systemImage: "archivebox")
                    }
                    NavigationLink {
                        SubscriptionManagementView(vpn: vpn, onShowDetail: onShowProfile)
                    } label: {
                        Label("订阅管理", systemImage: "arrow.clockwise")
                    }
                    NavigationLink {
                        SubscriptionRequestSettingsView()
                    } label: {
                        Label("订阅请求", systemImage: "network.badge.shield.half.filled")
                    }
                    NavigationLink {
                        ResourceManagementView(vpn: vpn)
                    } label: {
                        Label("资源管理", systemImage: "externaldrive")
                    }
                    NavigationLink {
                        ProxyShareView(vpn: vpn)
                    } label: {
                        Label("局域网共享", systemImage: "wifi")
                    }
                    NavigationLink {
                        AdvancedNetworkView(vpn: vpn)
                    } label: {
                        Label("高级网络", systemImage: "network")
                    }
                    NavigationLink {
                        ConfigurationOverridesView(vpn: vpn)
                    } label: {
                        Label("全局覆写", systemImage: "slider.horizontal.3")
                    }
                    NavigationLink {
                        ProvidersView(vpn: vpn)
                    } label: {
                        Label("节点与规则 Providers", systemImage: "square.stack.3d.up")
                    }
                }

                if vpn.status == .connected {
                    Section("DNS 缓存") {
                        Button("清理 DNS 缓存") { flushDNS(fakeIP: false) }
                        Button("清理 Fake-IP 缓存") { flushDNS(fakeIP: true) }
                    }
                }

                Section("延迟测试") {
                    Picker("超时", selection: $delayTimeout) {
                        ForEach([1, 2, 3, 5, 8, 10, 15], id: \.self) { seconds in
                            Text("\(seconds) 秒").tag(seconds * 1000)
                        }
                    }
                }

                Section("外观") {
                    NavigationLink {
                        AppearanceSettingsView()
                    } label: {
                        Label("外观与强调色", systemImage: "paintpalette")
                    }
                }

                Section("帮助与隐私") {
                    NavigationLink {
                        compatibilityDetails
                    } label: {
                        Label("配置兼容性", systemImage: "doc.text")
                    }
                    NavigationLink {
                        NetworkQualityView()
                    } label: {
                        Label("网络质量与 NAT", systemImage: "waveform.path.ecg")
                    }
                    NavigationLink {
                        DNSDiagnosticsView(vpn: vpn)
                    } label: {
                        Label("DNS 排查", systemImage: "magnifyingglass")
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
        .toast(vpn.toast)
    }

    private func flushDNS(fakeIP: Bool) {
        Task {
            do {
                try await vpn.live.flushDNSCache(fakeIP: fakeIP)
                vpn.showToast("缓存已清理", isSuccess: true)
            } catch { vpn.showToast(error.localizedDescription) }
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
