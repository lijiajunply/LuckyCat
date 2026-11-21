import SwiftUI

struct ProfilesView: View {
    let vpn: PrototypeVPN
    var onImportFile: () -> Void
    var onPaste: () -> Void
    var onImportURL: () -> Void
    var onImportQR: () -> Void
    var onShowDetail: (UUID) -> Void
    var onDelete: (Profile) -> Void
    var onShowConnection: () -> Void
    var onShowInfo: () -> Void

    private var profile: Profile? { vpn.library.selectedProfile }

    var body: some View {
        NavigationStack {
            List {
                if let profile {
                    currentProfileSection(profile)
                    if profile.sourceURL != nil {
                        subscriptionSection(profile)
                    }
                    if let groups = profile.clashGroups, !groups.isEmpty {
                        groupsSection(profile: profile, groups: groups)
                    }
                    nodesSection(profile)
                    importSection
                } else {
                    importSection
                    Section {
                        ContentUnavailableView(
                            "尚未选择配置",
                            systemImage: "folder.badge.questionmark",
                            description: Text("在连接页选择一个配置，或直接导入新配置。")
                        )
                        Button("前往连接页") { onShowConnection() }
                    }
                }
            }
            .navigationTitle("配置")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        onShowInfo()
                    } label: {
                        Image(systemName: "info.circle")
                            .accessibilityLabel("连接信息")
                            .accessibilityIdentifier("connection-info")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    latencyToolbarItem
                    if let profile {
                        Button {
                            onShowDetail(profile.id)
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .accessibilityLabel("详情与编辑")
                        }
                        .disabled(vpn.busy || vpn.isActive)
                        Button(role: .destructive) {
                            onDelete(profile)
                        } label: {
                            Image(systemName: "trash")
                                .accessibilityLabel("删除配置")
                        }
                        .accessibilityIdentifier("delete-profile-\(profile.name)")
                        .disabled(vpn.busy || vpn.isActive)
                    }
                }
            }
        }
    }

    @ViewBuilder private var latencyToolbarItem: some View {
        if vpn.latencyTesting, let profile, vpn.latencyProfileID == profile.id {
            Button("取消") { vpn.cancelLatencyTest() }
        } else if profile != nil {
            Button {
                Task { await vpn.testLatency() }
            } label: {
                Image(systemName: "speedometer")
                    .accessibilityLabel("延迟测试")
            }
            .disabled(vpn.busy || vpn.isActive)
            .accessibilityIdentifier("latency-test-toolbar")
        }
    }

    @ViewBuilder private func currentProfileSection(_ profile: Profile) -> some View {
        Section {
            if let node = profile.selectedNode {
                LabeledContent("节点", value: node.name)
            }
            if let group = profile.clashGroup, !group.isEmpty {
                LabeledContent("策略组", value: group)
            }
            if vpn.latencyTesting, vpn.latencyProfileID == profile.id {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在测试节点延迟…")
                    Spacer()
                    Button("取消") { vpn.cancelLatencyTest() }
                        .buttonStyle(.borderless)
                }
            } else {
                Button {
                    Task { await vpn.testLatency() }
                } label: {
                    Label("延迟测试", systemImage: "speedometer")
                }
                .disabled(vpn.busy || vpn.isActive)
                .accessibilityIdentifier("latency-test")
            }
            if let message = vpn.message {
                MessageLabel(text: message)
            }
        } header: {
            Text(profile.name)
                .textCase(nil)
        } footer: {
            if vpn.isActive {
                Text("断开 VPN 后可进行延迟测试。")
            } else {
                Text("延迟测试会逐个访问配置中的节点并显示连接延迟。")
            }
        }
    }

    @ViewBuilder private func subscriptionSection(_ profile: Profile) -> some View {
        Section {
            if let subscription = profile.subscription {
                LabeledContent("流量", value: ImportSummary.flow(subscription))
                LabeledContent("到期", value: ImportSummary.expiry(subscription.expire))
            }
            Toggle("自动更新", isOn: autoUpdateBinding(profile.id))
                .disabled(vpn.busy || vpn.isActive)
            Button {
                Task { await vpn.update(profile) }
            } label: {
                if vpn.updatingProfileID == profile.id {
                    HStack {
                        ProgressView()
                        Text("正在更新…")
                    }
                } else {
                    Label(
                        profile.resolvedEngine == .clash ? "更新订阅" : "更新配置",
                        systemImage: "arrow.clockwise"
                    )
                }
            }
            .accessibilityIdentifier("update-profile-\(profile.name)")
            .disabled(vpn.busy || vpn.isActive)
        } header: {
            Text("订阅")
        }
    }

    @ViewBuilder private func groupsSection(profile: Profile, groups: [ClashImportGroup]) -> some View {
        Section {
            ForEach(groups, id: \.name) { group in
                NavigationLink {
                    ClashGroupDetailView(vpn: vpn, profileID: profile.id, group: group)
                } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.name)
                            Text("\(group.type) · \(group.members.count) 个成员")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if profile.clashGroup == group.name {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                                .accessibilityLabel("当前策略组")
                        }
                    }
                }
            }
        } header: {
            Text("策略组")
        } footer: {
            Text("进入策略组可以查看成员、当前选择和每个节点的延迟。")
        }
    }

    @ViewBuilder private func nodesSection(_ profile: Profile) -> some View {
        Section("节点") {
            if profile.nodes.isEmpty {
                Text("该配置没有本地节点。节点可能由 proxy-providers 在连接时加载。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(profile.nodes) { node in
                    ProfileNodeRow(vpn: vpn, profile: profile, node: node)
                }
            }
        }
    }

    @ViewBuilder private var importSection: some View {
        Section {
            Button("从文件导入", systemImage: "document.badge.plus") { onImportFile() }
            Button("粘贴配置", systemImage: "clipboard") { onPaste() }
            Button("从 URL 导入", systemImage: "link") { onImportURL() }
                .accessibilityIdentifier("url-import")
            Button("二维码导入", systemImage: "qrcode.viewfinder") { onImportQR() }
            if vpn.library.profiles.contains(where: { $0.sourceURL != nil }) {
                Button("全部更新", systemImage: "arrow.triangle.2.circlepath") {
                    Task { await vpn.updateAll() }
                }
            }
            if let error = vpn.importError {
                Text(error).foregroundStyle(.orange)
            }
            if vpn.library.selectedProfile == nil, let message = vpn.message {
                MessageLabel(text: message)
            }
        } header: {
            Text("添加配置")
        } footer: {
            Text("支持 Clash YAML、订阅链接、分享链接和二维码。VPN 连接期间不能导入或更新。")
        }
        .disabled(vpn.busy || vpn.isActive)
    }

    private func autoUpdateBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: {
                vpn.library.profiles.first(where: { $0.id == id })?.autoUpdateEnabled ?? true
            },
            set: { vpn.setAutoUpdate($0, for: id) }
        )
    }
}

struct ProfileNodeRow: View {
    let vpn: PrototypeVPN
    let profile: Profile
    let node: Profile.Node

    var body: some View {
        Button {
            guard !vpn.busy, !vpn.isActive else { return }
            vpn.select(profileID: profile.id, nodeID: node.id)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name)
                        .foregroundStyle(.primary)
                    Text(node.type ?? "node")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                LatencyBadge(state: vpn.latencyState(for: node.name, profileID: profile.id))
                if profile.selectedNodeID == node.id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("当前节点")
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("node-\(profile.name)-\(node.name)")
    }
}

struct LatencyBadge: View {
    let state: LatencyState

    var body: some View {
        switch state {
        case .untested:
            EmptyView()
        case .testing:
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel("正在测试延迟")
        case .value(let delay):
            Text("\(delay) ms")
                .font(.caption.monospacedDigit())
                .foregroundStyle(color(for: delay))
                .accessibilityLabel("延迟 \(delay) 毫秒")
        case .failed:
            Text("超时")
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityLabel("延迟测试超时")
        }
    }

    private func color(for delay: Int) -> Color {
        switch delay {
        case ..<100: .green
        case ..<250: .orange
        default: .red
        }
    }
}

struct ClashGroupDetailView: View {
    let vpn: PrototypeVPN
    let profileID: UUID
    let group: ClashImportGroup

    private var profile: Profile? {
        vpn.library.profiles.first { $0.id == profileID }
    }

    var body: some View {
        List {
            Section {
                LabeledContent("类型", value: group.type)
                LabeledContent("成员", value: "\(group.members.count)")
                if profile?.clashGroup == group.name {
                    LabeledContent("状态", value: "当前使用")
                }
            }
            Section {
                if group.members.isEmpty {
                    Text("该策略组暂无成员。").foregroundStyle(.secondary)
                } else {
                    ForEach(group.members, id: \.self) { member in
                        memberRow(member)
                    }
                }
            } header: {
                Text("成员")
            } footer: {
                if !group.isSelectable {
                    Text("该策略组由内核按延迟自动选择节点，不能手动切换。")
                }
            }
        }
        .navigationTitle(group.name)
    }

    @ViewBuilder private func memberRow(_ member: String) -> some View {
        if let profile, let node = profile.nodes.first(where: { $0.name == member }) {
            if group.isSelectable {
                Button {
                    guard !vpn.busy, !vpn.isActive else { return }
                    vpn.select(profileID: profile.id, nodeID: node.id, group: group.name)
                } label: {
                    memberLabel(member, node: node, profile: profile)
                }
                .buttonStyle(.plain)
            } else {
                memberLabel(member, node: node, profile: profile)
            }
        } else {
            HStack {
                Text(member)
                Spacer()
                Text("配置内引用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func memberLabel(
        _ member: String, node: Profile.Node, profile: Profile
    ) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(member)
                    .foregroundStyle(.primary)
                Text(node.type ?? "node")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            LatencyBadge(state: vpn.latencyState(for: member, profileID: profile.id))
            if profile.selectedNodeID == node.id, profile.clashGroup == group.name {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .accessibilityLabel("当前选择")
            }
        }
    }
}

struct ProfileDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let vpn: PrototypeVPN
    let profileID: UUID

    @State private var draftName = ""
    @State private var showingDelete = false

    private var profile: Profile? {
        vpn.library.profiles.first { $0.id == profileID }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let profile {
                    Section("名称") {
                        TextField("配置名称", text: $draftName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("profile-detail-name")
                            .onSubmit { saveName(profile) }
                        if trimmedName != profile.name {
                            Button("保存名称") { saveName(profile) }
                                .disabled(trimmedName.isEmpty || vpn.busy || vpn.isActive)
                        }
                    }

                    Section("当前配置") {
                        LabeledContent("节点", value: profile.selectedNode?.name ?? "未选择")
                        LabeledContent(
                            "策略组",
                            value: profile.clashGroup.flatMap { $0.isEmpty ? nil : $0 } ?? "未指定"
                        )
                        if let source = profile.sourceURL {
                            LabeledContent("来源", value: source.host() ?? "链接")
                        }
                    }

                    if profile.sourceURL != nil {
                        Section("订阅") {
                            if let subscription = profile.subscription {
                                LabeledContent("流量", value: ImportSummary.flow(subscription))
                                LabeledContent("到期", value: ImportSummary.expiry(subscription.expire))
                                if let updated = subscription.lastUpdated {
                                    LabeledContent(
                                        "上次更新",
                                        value: updated.formatted(date: .abbreviated, time: .shortened)
                                    )
                                }
                            }
                            Toggle("自动更新", isOn: autoUpdateBinding(profile.id))
                                .disabled(vpn.busy || vpn.isActive)
                            Button {
                                Task { await vpn.update(profile) }
                            } label: {
                                if vpn.updatingProfileID == profile.id {
                                    HStack {
                                        ProgressView()
                                        Text("正在更新…")
                                    }
                                } else {
                                    Label("更新订阅", systemImage: "arrow.clockwise")
                                }
                            }
                            .disabled(vpn.busy || vpn.isActive)
                        }
                    }

                    if let groups = profile.clashGroups, !groups.isEmpty {
                        Section("策略组") {
                            ForEach(groups, id: \.name) { group in
                                NavigationLink {
                                    ClashGroupDetailView(
                                        vpn: vpn, profileID: profile.id, group: group
                                    )
                                } label: {
                                    HStack {
                                        Text(group.name)
                                        Spacer()
                                        Text("\(group.members.count)")
                                            .foregroundStyle(.secondary)
                                        if profile.clashGroup == group.name {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(.tint)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Section("节点") {
                        if profile.nodes.isEmpty {
                            Text("该配置没有本地节点。").foregroundStyle(.secondary)
                        } else {
                            ForEach(profile.nodes) { node in
                                ProfileNodeRow(vpn: vpn, profile: profile, node: node)
                            }
                        }
                    }

                    Section {
                        NavigationLink("兼容提示") {
                            ProfileCompatibility(profile: profile)
                        }
                        Button("删除配置", role: .destructive) {
                            showingDelete = true
                        }
                        .disabled(vpn.busy || vpn.isActive)
                    }
                } else {
                    ContentUnavailableView(
                        "配置已删除",
                        systemImage: "trash",
                        description: Text("该配置已从本机移除。")
                    )
                }
            }
            .navigationTitle("配置详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task {
                if draftName.isEmpty {
                    draftName = profile?.name ?? ""
                }
            }
            .alert("删除配置？", isPresented: $showingDelete) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    guard let profile else { return }
                    Task {
                        await vpn.remove(profile)
                        if !vpn.library.profiles.contains(where: { $0.id == profile.id }) {
                            dismiss()
                        }
                    }
                }
            } message: {
                Text("将从本机删除「\(profile?.name ?? "该配置")」及其节点凭据。")
            }
        }
    }

    private var trimmedName: String {
        String(draftName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
    }

    private func saveName(_ profile: Profile) {
        let name = trimmedName
        guard !name.isEmpty, name != profile.name else { return }
        vpn.rename(profileID: profile.id, to: name)
        draftName = name
    }

    private func autoUpdateBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: {
                vpn.library.profiles.first(where: { $0.id == id })?.autoUpdateEnabled ?? true
            },
            set: { vpn.setAutoUpdate($0, for: id) }
        )
    }
}

struct ProfileCompatibility: View {
    let profile: Profile

    var body: some View {
        List {
            if profile.nodes.isEmpty {
                Text("该配置没有本地节点，节点由 proxy-providers 在连接时加载。")
                    .foregroundStyle(.secondary)
            }
            ForEach(profile.nodes) { node in
                Section(node.name) {
                    LabeledContent("远端", value: node.endpoint)
                    ForEach(node.compatibilityNotes, id: \.self) { note in
                        Text(note)
                    }
                }
            }
        }
        .navigationTitle("兼容提示")
    }
}
