import SwiftUI

struct ImportPreview: View {
    @Environment(\.dismiss) private var dismiss
    let vpn: PrototypeVPN
    @State var selectedNode: String
    @State private var name: String

    init(vpn: PrototypeVPN, selectedNode: String, initialName: String = "") {
        self.vpn = vpn
        _selectedNode = State(initialValue: selectedNode)
        _name = State(initialValue: initialName)
    }

    /// The default name used when the name field is left empty.
    private var resolvedName: String {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed.isEmpty else { return String(typed.prefix(80)) }
        let suggested = vpn.defaultImportName
        if !suggested.isEmpty { return suggested }
        return selectedNode.isEmpty
            ? (vpn.stagedEngine == .clash ? "Clash 配置" : "配置")
            : selectedNode
    }

    private var namePlaceholder: String {
        let suggested = vpn.defaultImportName
        return suggested.isEmpty
            ? "配置名称（留空使用默认名称）"
            : "配置名称（留空使用「\(suggested)」）"
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(namePlaceholder, text: $name)
                    .accessibilityIdentifier("import-name")
                if let source = vpn.stagedSourceURL {
                    LabeledContent("来源", value: source.host() ?? "链接")
                }
                LabeledContent("类型", value: vpn.stagedEngine == .clash ? "Clash" : "WireGuard")
                if let subscription = vpn.stagedSubscription {
                    LabeledContent(
                        "流量",
                        value: ImportSummary.flow(subscription)
                    )
                    LabeledContent("到期", value: ImportSummary.expiry(subscription.expire))
                }
                if !vpn.stagedGroups.isEmpty {
                    LabeledContent("策略组", value: "\(vpn.stagedGroups.count) 个")
                }
                if !vpn.importedRules.isEmpty {
                    LabeledContent("规则", value: "\(vpn.importedRules.count) 条")
                }
                if !vpn.importWarnings.isEmpty {
                    Section("导入提示") {
                        ForEach(vpn.importWarnings, id: \.self) { warning in
                            Text(warning).foregroundStyle(.orange)
                        }
                    }
                }
                if vpn.imported.isEmpty {
                    Section("节点") {
                        Text("节点由配置中的 proxy-providers 提供，连接时由内核加载。")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("选择默认节点") {
                        Picker("节点", selection: $selectedNode) {
                            ForEach(vpn.imported) { node in
                                Text(node.endpoint.isEmpty
                                    ? "\(node.name) · \(node.type)"
                                    : "\(node.name) · \(node.type) · \(node.endpoint)")
                                    .tag(node.id)
                            }
                        }
                        .pickerStyle(.inline)
                    }
                }
                if let node = vpn.imported.first(where: { $0.id == selectedNode }) {
                    Section("节点兼容性") {
                        LabeledContent("协议", value: node.type)
                        if let configuration = node.configuration {
                            LabeledContent("IPv4", value: configuration.clientIPv4)
                            LabeledContent("IPv6", value: configuration.clientIPv6)
                            LabeledContent("DNS", value: configuration.dnsServers.joined(separator: ", "))
                            Text("旧版 WireGuard 参数会转换为 Clash 配置，由内核在隧道内执行。")
                                .foregroundStyle(.secondary)
                        } else {
                            if !node.endpoint.isEmpty {
                                LabeledContent("远端", value: node.endpoint)
                            }
                            Text("由 Clash 内核按配置中的代理组和规则分流，支持 ss / vmess / vless / trojan / hysteria2 / tuic / wireguard 等节点。")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let error = vpn.importError { Text(error).foregroundStyle(.orange) }
            }
            .navigationTitle("导入预览")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if vpn.saveImport(named: resolvedName, selectedNode: selectedNode) {
                            dismiss()
                        }
                    }
                    .disabled(vpn.imported.isEmpty && vpn.stagedEngine != .clash)
                }
            }
        }
    }
}

#if DEBUG
#Preview("导入预览") {
    ImportPreview(
        vpn: .previewStaged(),
        selectedNode: PreviewSamples.importedNodes[0].id
    )
}
#endif
