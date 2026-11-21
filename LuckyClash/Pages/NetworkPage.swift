import SwiftUI

/// Live view of what the tunnel's Clash core is doing: the connections it is
/// carrying and the log lines it emits. Data comes from the core's control
/// socket, so it is only available while the tunnel is running.
struct NetworkPage: View {
    enum Feed: String, CaseIterable, Identifiable {
        case connections
        case logs

        var id: String { rawValue }

        var title: String {
            switch self {
            case .connections: "连接"
            case .logs: "日志"
            }
        }
    }

    enum LevelFilter: String, CaseIterable, Identifiable {
        case all
        case info
        case warning
        case error
        case debug

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "全部级别"
            case .info: "信息"
            case .warning: "警告"
            case .error: "错误"
            case .debug: "调试"
            }
        }

        func matches(_ level: ClashLogEntry.Level) -> Bool {
            switch self {
            case .all: true
            case .info: level == .info
            case .warning: level == .warning
            case .error: level == .error
            case .debug: level == .debug
            }
        }
    }

    let vpn: PrototypeVPN

    @State private var feed: Feed
    @State private var search = ""
    @State private var level: LevelFilter = .all
    @State private var selectedConnection: ClashConnection?
    @State private var showingClear = false

    init(vpn: PrototypeVPN, initialFeed: Feed = .connections) {
        self.vpn = vpn
        _feed = State(initialValue: initialFeed)
    }

    private var store: NetworkStore { vpn.network }

    var body: some View {
        NavigationStack {
            List {
                feedSection
                if feed == .connections {
                    connectionsContent
                } else {
                    logsContent
                }
                statusSection
            }
            .navigationTitle("网络日志")
            .searchable(
                text: $search,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: searchPrompt
            )
            .toolbar { toolbarContent }
            .sheet(item: $selectedConnection) { connection in
                ConnectionDetailView(connection: connection)
            }
            .alert("清除日志？", isPresented: $showingClear) {
                Button("取消", role: .cancel) {}
                Button("清除", role: .destructive) { store.clearLogs() }
            } message: {
                Text("将清空当前显示的日志，不影响 VPN 连接。")
            }
            .alert("内核操作失败", isPresented: errorBinding) {
                Button("好") { store.dismissError() }
            } message: {
                Text(store.errorMessage ?? "")
            }
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusTitle)
                Spacer()
                if let updated = store.lastUpdated, store.status == .streaming {
                    Text(updated, format: .dateTime.hour().minute().second())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if store.status == .streaming {
                LabeledContent("会话流量", value: "↓ \(bytes(store.downloadTotal)) · ↑ \(bytes(store.uploadTotal))")
                LabeledContent("实时速率", value: "↓ \(rate(store.downloadRate))/s · ↑ \(rate(store.uploadRate))/s")
            }
        } footer: {
            Text(statusHint)
        }
    }

    private var statusColor: Color {
        switch store.status {
        case .streaming: .green
        case .waiting: .orange
        case .idle: Color.secondary
        }
    }

    private var statusTitle: String {
        switch store.status {
        case .streaming: "实时监听内核"
        case .waiting: "等待内核"
        case .idle: store.connections.isEmpty && store.logs.isEmpty ? "未连接" : "显示上次会话"
        }
    }

    private var statusHint: String {
        switch store.status {
        case .streaming:
            "连接列表每秒刷新，日志在到达时追加。可通过滑动关闭单条连接。"
        case .waiting:
            vpn.isActive
                ? "已连接 VPN，但内核控制通道暂未就绪。若持续显示，请尝试重新连接。"
                : "正在等待 VPN 内核启动。连接 VPN 后会自动接入，无需刷新。"
        case .idle:
            "连接 VPN 后可查看实时连接与内核日志。"
        }
    }

    // MARK: - Feed picker

    private var feedSection: some View {
        Section {
            Picker("视图", selection: $feed) {
                ForEach(Feed.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("network-feed")
            .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
            .listRowBackground(Color.clear)
        }
    }

    // MARK: - Connections

    private var filteredConnections: [ClashConnection] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return store.connections }
        return store.connections.filter { connection in
            [
                connection.destinationName,
                connection.metadata.host,
                connection.metadata.sniffHost,
                connection.metadata.destinationIP,
                connection.rule,
                connection.rulePayload,
                connection.chains.joined(separator: " "),
            ]
            .joined(separator: " ")
            .lowercased()
            .contains(query)
        }
    }

    @ViewBuilder private var connectionsContent: some View {
        let connections = filteredConnections
        if connections.isEmpty {
            Section {
                ContentUnavailableView(
                    search.isEmpty ? "暂无活动连接" : "没有匹配的连接",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text(emptyConnectionsHint)
                )
            }
        } else {
            Section {
                ForEach(connections) { connection in
                    connectionRow(connection)
                }
            } header: {
                HStack {
                    Text("活动连接 \(connections.count)")
                    Spacer()
                    Text("↓ \(bytes(store.downloadTotal)) · ↑ \(bytes(store.uploadTotal))")
                        .font(.caption.monospacedDigit())
                }
            }
        }
    }

    private var emptyConnectionsHint: String {
        switch store.status {
        case .streaming: "当前没有经过内核的连接。打开网页或应用后会自动出现。"
        case .waiting: "内核启动后，连接会自动出现在这里。"
        case .idle: "连接 VPN 后，内核处理的连接会显示在这里。"
        }
    }

    private func connectionRow(_ connection: ClashConnection) -> some View {
        Button {
            selectedConnection = connection
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: connection.isRejected
                    ? "nosign"
                    : (connection.isDirect ? "arrow.right.circle" : "arrow.triangle.branch"))
                    .foregroundStyle(
                        connection.isRejected
                            ? Color.red
                            : (connection.isDirect ? Color.secondary : Color.accentColor)
                    )
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(connection.destinationWithPort)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(connectionSubtitle(connection))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("↓ \(bytes(connection.download))")
                        .font(.caption.monospacedDigit())
                    Text("↑ \(bytes(connection.upload))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("connection-\(connection.id)")
        .swipeActions(edge: .trailing) {
            if store.status == .streaming {
                Button(role: .destructive) {
                    Task { await store.closeConnection(connection.id) }
                } label: {
                    Label("关闭", systemImage: "xmark.circle")
                }
            }
        }
    }

    private func connectionSubtitle(_ connection: ClashConnection) -> String {
        var parts: [String] = []
        if !connection.metadata.network.isEmpty {
            parts.append(connection.metadata.network.uppercased())
        }
        if !connection.ruleSummary.isEmpty {
            parts.append(connection.ruleSummary)
        }
        if !connection.chains.isEmpty {
            parts.append(connection.outboundName)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Logs

    private var filteredLogs: [ClashLogEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return store.logs.filter { entry in
            guard level.matches(entry.level) else { return false }
            guard !query.isEmpty else { return true }
            return entry.payload.lowercased().contains(query)
                || (entry.tag?.lowercased().contains(query) ?? false)
        }
    }

    @ViewBuilder private var logsContent: some View {
        let logs = filteredLogs
        if logs.isEmpty {
            Section {
                ContentUnavailableView(
                    search.isEmpty && level == .all ? "暂无日志" : "没有匹配的日志",
                    systemImage: "text.alignleft",
                    description: Text("内核日志会在运行时追加到这里。")
                )
            }
        } else {
            Section {
                ForEach(logs.reversed()) { entry in
                    logRow(entry)
                }
            } header: {
                HStack {
                    Text("日志 \(logs.count)")
                    Spacer()
                    Text("最新在上")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func logRow(_ entry: ClashLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(entry.date, format: .dateTime.hour().minute().second())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(entry.level.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(levelColor(entry.level))
                if let tag = entry.tag {
                    Text(tag)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            Text(entry.payload)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(8)
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("log-\(entry.id.uuidString)")
    }

    private func levelColor(_ level: ClashLogEntry.Level) -> Color {
        switch level {
        case .warning: .orange
        case .error: .red
        case .info, .debug, .silent: .secondary
        }
    }

    private var exportText: String {
        filteredLogs.map { entry in
            let time = entry.date.formatted(date: .omitted, time: .standard)
            return "\(time) [\(entry.level.title)] \(entry.payload)"
        }
        .joined(separator: "\n")
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        switch feed {
        case .connections:
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await store.closeAllConnections() }
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .accessibilityLabel("关闭全部连接")
                .disabled(store.connections.isEmpty || store.status != .streaming)
            }
        case .logs:
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("级别", selection: $level) {
                        ForEach(LevelFilter.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    ShareLink(item: exportText) {
                        Label("导出日志", systemImage: "square.and.arrow.up")
                    }
                    .disabled(filteredLogs.isEmpty)
                    Button(role: .destructive) {
                        showingClear = true
                    } label: {
                        Label("清除日志", systemImage: "trash")
                    }
                    .disabled(store.logs.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("日志操作")
            }
        }
    }

    // MARK: - Footer

    private var privacySection: some View {
        Section {
            Text("连接与日志只保存在本机内存，不会写入诊断或上传；退出 App 后清空。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Formatting

    private var searchPrompt: String {
        feed == .connections ? "搜索域名、规则或节点" : "搜索日志"
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.dismissError() } }
        )
    }

    private func bytes(_ count: UInt64) -> String {
        ImportSummary.bytes(count)
    }

    private func rate(_ value: Int64) -> String {
        ImportSummary.bytes(UInt64(max(0, value)))
    }
}

#if DEBUG
#Preview("网络 · 连接") {
    NetworkPage(vpn: .previewNetwork())
}

#Preview("网络 · 日志") {
    NetworkPage(vpn: .previewNetwork(), initialFeed: .logs)
}

#Preview("网络 · 未连接") {
    NetworkPage(vpn: .previewNetwork(status: .idle))
}
#endif
