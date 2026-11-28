import NetworkExtension
import SwiftUI

struct ProvidersView: View {
    let vpn: PrototypeVPN
    @State private var providers: [ClashProvider] = []
    @State private var operation: String?
    @State private var error: String?

    var body: some View {
        List {
            if vpn.status != .connected {
                ContentUnavailableView("连接后查看 Providers", systemImage: "square.stack.3d.up")
            } else {
                if let error {
                    Label(error, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                }
                section("节点 Providers", kind: .proxy)
                section("规则 Providers", kind: .rule)
            }
        }
        .navigationTitle("Providers")
        .task(id: vpn.status) { await refresh() }
        .refreshable { await refresh() }
    }

    private func section(_ title: String, kind: ClashProvider.Kind) -> some View {
        Section(title) {
            let entries = providers.filter { $0.kind == kind }
            if entries.isEmpty { Text("暂无数据").foregroundStyle(.secondary) }
            ForEach(entries) { provider in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(provider.name).font(.headline)
                        Spacer()
                        if operation == provider.id {
                            ProgressView()
                        } else {
                            Menu("操作", systemImage: "ellipsis.circle") {
                                Button("更新", systemImage: "arrow.clockwise") {
                                    Task { await perform(provider, healthCheck: false) }
                                }
                                if provider.kind == .proxy {
                                    Button("健康检查", systemImage: "heart.text.square") {
                                        Task { await perform(provider, healthCheck: true) }
                                    }
                                }
                            }
                            .labelStyle(.iconOnly)
                            .disabled(operation != nil || vpn.switchingProfile)
                        }
                    }
                    Text(countText(provider))
                    if let date = provider.payload.updateDate {
                        Text("更新于 \(date.formatted(date: .abbreviated, time: .shortened))")
                    }
                    if let usage = provider.payload.subscriptionInfo {
                        let used = Double(max(0, usage.download ?? 0)) + Double(max(0, usage.upload ?? 0))
                        let usedText = bytes(used)
                        if let total = usage.total, total > 0 {
                            Text("订阅流量 \(usedText) / \(bytes(Double(total)))")
                        } else {
                            Text("已用流量 \(usedText)")
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
            }
        }
    }

    private func countText(_ provider: ClashProvider) -> String {
        switch provider.kind {
        case .proxy: "\(provider.payload.proxies?.count ?? 0) 个节点"
        case .rule: "\(provider.payload.ruleCount ?? 0) 条规则"
        }
    }

    private func bytes(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(Double(Int64.max / 2), value)), countStyle: .file)
    }

    private func refresh() async {
        guard vpn.status == .connected else {
            providers = []
            error = nil
            return
        }
        do {
            let current = try await vpn.live.providers()
            guard !Task.isCancelled, vpn.status == .connected else { return }
            providers = current
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func perform(_ provider: ClashProvider, healthCheck: Bool) async {
        guard operation == nil, vpn.status == .connected else { return }
        operation = provider.id
        defer { operation = nil }
        do {
            if healthCheck { try await vpn.live.healthCheckProvider(provider) }
            else { try await vpn.live.updateProvider(provider) }
            await refresh()
            await vpn.refreshLiveGroups()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
