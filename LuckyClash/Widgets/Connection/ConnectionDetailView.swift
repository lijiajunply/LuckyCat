import SwiftUI
import Darwin

/// Everything the core knows about one connection, including the rule and
/// proxy chain that routed it.
struct ConnectionDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let connection: ClashConnection
    var vpn: PrototypeVPN?
    @State private var addingRule = false
    @State private var ruleMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section("目标") {
                    row("域名", connection.metadata.host)
                    row("SNI", connection.metadata.sniffHost)
                    row("目的地址", destination)
                    row("远端", connection.metadata.remoteDestination)
                    row("目的地区", connection.metadata.destinationGeoIP.joined(separator: ", "))
                }
                Section("路由") {
                    row("规则", connection.ruleSummary)
                    row("节点链", connection.chains.joined(separator: " → "))
                    row("出站", connection.outboundName)
                }
                if let vpn, let profile = vpn.library.selectedProfile, let rule = rulePrefix {
                    Section("添加规则") {
                        Text(rule.target).font(.caption).foregroundStyle(.secondary)
                        Menu("添加到当前配置", systemImage: "plus.circle") {
                            Button("直连") { addRule(rule.prefix, policy: "DIRECT", profile: profile, vpn: vpn) }
                            Button("拒绝") { addRule(rule.prefix, policy: "REJECT", profile: profile, vpn: vpn) }
                            ForEach(profile.clashGroups ?? [], id: \.name) { group in
                                Button(group.name) { addRule(rule.prefix, policy: group.name, profile: profile, vpn: vpn) }
                            }
                        }
                        .disabled(addingRule || !vpn.canUpdateProfile(profile.id))
                        if let ruleMessage { Text(ruleMessage).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Section("传输") {
                    row("网络", connection.metadata.network.uppercased())
                    row("类型", connection.metadata.type)
                    row("来源", source)
                    row("DNS", connection.metadata.dnsMode)
                    if let start = connection.start {
                        LabeledContent(
                            "开始时间",
                            value: start.formatted(date: .abbreviated, time: .standard)
                        )
                    }
                    LabeledContent("接收", value: ImportSummary.bytes(connection.download))
                    LabeledContent("发送", value: ImportSummary.bytes(connection.upload))
                }
                if !connection.metadata.process.isEmpty || !connection.metadata.processPath.isEmpty {
                    Section("进程") {
                        row("名称", connection.metadata.process)
                        row("路径", connection.metadata.processPath)
                    }
                }
            }
            .navigationTitle("连接详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var rulePrefix: (prefix: String, target: String)? {
        let hostname = [connection.metadata.host, connection.metadata.sniffHost]
            .first { !$0.isEmpty && !$0.contains(",") && !$0.contains(where: \.isWhitespace) }
        if let hostname, !isIP(hostname, family: AF_INET), !isIP(hostname, family: AF_INET6) {
            return ("DOMAIN,\(hostname)", hostname)
        }
        let address = hostname ?? connection.metadata.destinationIP
        if isIP(address, family: AF_INET) { return ("IP-CIDR,\(address)/32", address) }
        if isIP(address, family: AF_INET6) { return ("IP-CIDR6,\(address)/128", address) }
        return nil
    }

    private func isIP(_ address: String, family: Int32) -> Bool {
        var buffer = in6_addr()
        return address.withCString { inet_pton(family, $0, &buffer) } == 1
    }

    private func addRule(_ prefix: String, policy: String, profile: Profile, vpn: PrototypeVPN) {
        guard !policy.contains(","), !policy.contains(where: \.isNewline) else {
            ruleMessage = "策略组名称无法用于规则。"
            return
        }
        addingRule = true
        Task {
            defer { addingRule = false }
            var overrides = profile.overrides ?? .empty
            let rule = "\(prefix),\(policy)"
            guard !overrides.prependRules.contains(rule) else {
                ruleMessage = "规则已存在。"
                return
            }
            overrides.prependRules.insert(rule, at: 0)
            do {
                try await vpn.saveOverrides(overrides, profileID: profile.id)
                ruleMessage = "规则已添加"
            } catch { ruleMessage = error.localizedDescription }
        }
    }

    private var destination: String {
        let address = connection.metadata.destinationIP
        let port = connection.metadata.destinationPort
        guard !address.isEmpty else { return "" }
        return port.isEmpty ? address : "\(address):\(port)"
    }

    private var source: String {
        let address = connection.metadata.sourceIP
        let port = connection.metadata.sourcePort
        guard !address.isEmpty else { return "" }
        return port.isEmpty ? address : "\(address):\(port)"
    }

    @ViewBuilder private func row(_ title: String, _ value: String) -> some View {
        if !value.isEmpty {
            LabeledContent(title, value: value)
        }
    }
}

#if DEBUG
#Preview("连接详情") {
    ConnectionDetailView(connection: PreviewSamples.connections[0])
}
#endif
