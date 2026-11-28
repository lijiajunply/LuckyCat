import SwiftUI

struct AdvancedNetworkView: View {
    let vpn: PrototypeVPN
    @AppStorage(TunnelNetworkOptions.ipv6Mode) private var ipv6 = "config"
    @AppStorage(TunnelNetworkOptions.queryMode) private var query = "config"
    @AppStorage(TunnelNetworkOptions.mtu) private var mtu = 0
    @AppStorage(TunnelNetworkOptions.includeAllNetworks) private var includeAll = false
    @AppStorage(TunnelNetworkOptions.bypassPrivate) private var bypassPrivate = false
    @AppStorage(TunnelNetworkOptions.statisticsProxyOnly) private var proxyOnly = false
    @AppStorage(TunnelNetworkOptions.onDemand) private var onDemand = false
    @AppStorage(TunnelNetworkOptions.excludedSSIDs) private var excludedSSIDs = ""
    @State private var applying = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Picker("TUN IPv6", selection: $ipv6) {
                    Text("跟随配置").tag("config")
                    Text("关闭").tag("disabled")
                    Text("自动").tag("automatic")
                    Text("开启").tag("enabled")
                }
                Picker("IP 查询", selection: $query) {
                    Text("跟随配置").tag("config")
                    Text("仅 IPv4").tag("ipv4-only")
                    Text("双栈").tag("dual-stack")
                    Text("优先 IPv4").tag("prefer-ipv4")
                    Text("优先 IPv6").tag("prefer-ipv6")
                    Text("仅 IPv6").tag("ipv6-only")
                }
                Picker("TUN MTU", selection: $mtu) {
                    Text("默认").tag(0)
                    ForEach([1280, 1400, 1500, 9000], id: \.self) { Text("\($0)").tag($0) }
                }
                Toggle("包含所有网络", isOn: $includeAll)
                Toggle("绕过私有地址", isOn: $bypassPrivate)
                Toggle("仅统计代理流量", isOn: $proxyOnly)
                    .onChange(of: proxyOnly) { _, value in
                        guard vpn.isActive else { return }
                        Task {
                            do { try await vpn.live.setOnlyStatisticsProxy(value) }
                            catch { message = error.localizedDescription }
                        }
                    }
            } footer: {
                Text("TUN 参数在下次连接时生效。")
            }
            Section {
                Toggle("按需连接", isOn: $onDemand)
                TextField("信任的 Wi-Fi 名称，每行一个", text: $excludedSSIDs, axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if onDemand && TunnelNetworkOptions.hasInvalidTrustedSSIDs(excludedSSIDs) {
                    Text("每个 Wi-Fi 名称最多 32 字节。")
                        .font(.footnote).foregroundStyle(.red)
                }
                Button("应用按需连接设置") {
                    applying = true
                    Task {
                        defer { applying = false }
                        do {
                            try await vpn.applyOnDemandSettings()
                            message = "按需连接设置已应用"
                        } catch { message = error.localizedDescription }
                    }
                }
                .disabled(applying || vpn.busy || vpn.switchingProfile || (onDemand && TunnelNetworkOptions.hasInvalidTrustedSSIDs(excludedSSIDs)))
            } footer: {
                Text("连接信任的 Wi-Fi 时断开 VPN，其他网络自动连接。")
            }
            if let message { Text(message).foregroundStyle(.secondary) }
        }
        .navigationTitle("高级网络")
    }
}
