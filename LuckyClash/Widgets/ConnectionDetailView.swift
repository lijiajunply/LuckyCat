import SwiftUI

/// Everything the core knows about one connection, including the rule and
/// proxy chain that routed it.
struct ConnectionDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let connection: ClashConnection

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
