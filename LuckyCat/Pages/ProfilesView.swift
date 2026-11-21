import SwiftUI

struct ProfilesView: View {
    let vpn: PrototypeVPN
    var onShowDetail: (UUID) -> Void
    var onDelete: (Profile) -> Void
    var onShowConnection: () -> Void
    var onShowInfo: () -> Void

    private var profile: Profile? { vpn.library.selectedProfile }

    var body: some View {
        NavigationStack {
            List {
                if let message = vpn.message {
                    Section {
                        MessageLabel(text: message)
                    }
                }
                if let profile {
                    if let groups = profile.clashGroups, !groups.isEmpty {
                        groupsSection(profile: profile, groups: groups)
                    }
                    nodesSection(profile)
                    if profile.sourceURL != nil {
                        subscriptionSection(profile)
                    }
                } else {
                    Section {
                        ContentUnavailableView(
                            "尚未选择配置",
                            systemImage: "folder.badge.questionmark",
                            description: Text("在连接页选择一个配置，或从连接页导入新配置。")
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
            .disabled(vpn.busy)
            .accessibilityIdentifier("latency-test-toolbar")
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
        }
    }

    @ViewBuilder private func nodesSection(_ profile: Profile) -> some View {
        Section {
            if profile.nodes.isEmpty {
                Text("该配置没有本地节点。节点可能由 proxy-providers 在连接时加载。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(profile.nodes) { node in
                    ProfileNodeRow(vpn: vpn, profile: profile, node: node)
                }
            }
        } header: {
            Text("节点")
        } footer: {
            if vpn.isActive && vpn.canSwitchNodes(for: profile.id) {
                Text("连接中切换会立即应用到新连接，已有连接保持原节点。")
            } else if vpn.isActive {
                Text("断开 VPN 后才能切换其他配置的节点。")
            }
        }
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
            guard vpn.canSwitchNodes(for: profile.id) else { return }
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
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
                } else if vpn.isActive && vpn.canSwitchNodes(for: profileID) {
                    Text("连接中切换会立即应用到新连接，已有连接保持原节点。")
                }
            }
        }
        .navigationTitle(group.name)
    }

    @ViewBuilder private func memberRow(_ member: String) -> some View {
        if let profile, let node = profile.nodes.first(where: { $0.name == member }) {
            if group.isSelectable {
                Button {
                    guard vpn.canSwitchNodes(for: profile.id) else { return }
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
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

#if DEBUG
// MARK: - Pages

#Preview("配置页 · 订阅") {
    ProfilesView(
        vpn: .preview(
            latencyResults: PreviewSamples.latencyResults(forProfile: PreviewSamples.profileID)
        ),
        onShowDetail: { _ in },
        onDelete: { _ in },
        onShowConnection: {},
        onShowInfo: {}
    )
}

#Preview("配置页 · 订阅即将到期") {
    ProfilesView(
        vpn: .preview(
            library: PreviewSamples.library(profiles: [PreviewSamples.expiringSubscriptionProfile])
        ),
        onShowDetail: { _ in },
        onDelete: { _ in },
        onShowConnection: {},
        onShowInfo: {}
    )
}

#Preview("配置页 · 本地配置") {
    ProfilesView(
        vpn: .preview(
            library: PreviewSamples.library(
                profiles: [PreviewSamples.localProfile],
                selectedProfileID: PreviewSamples.localProfileID
            )
        ),
        onShowDetail: { _ in },
        onDelete: { _ in },
        onShowConnection: {},
        onShowInfo: {}
    )
}

#Preview("配置页 · 空") {
    ProfilesView(
        vpn: .preview(library: ProfileLibrary()),
        onShowDetail: { _ in },
        onDelete: { _ in },
        onShowConnection: {},
        onShowInfo: {}
    )
}

#Preview("配置页 · 延迟测试中") {
    ProfilesView(
        vpn: .preview(
            latencyTesting: true,
            latencyProfileID: PreviewSamples.profileID
        ),
        onShowDetail: { _ in },
        onDelete: { _ in },
        onShowConnection: {},
        onShowInfo: {}
    )
}

// MARK: - Rows

#Preview("节点行") {
    let vpn = PrototypeVPN.preview(
        latencyResults: PreviewSamples.latencyResults(forProfile: PreviewSamples.profileID)
    )
    return List {
        ProfileNodeRow(
            vpn: vpn,
            profile: PreviewSamples.subscriptionProfile,
            node: PreviewSamples.hongKong
        )
        ProfileNodeRow(
            vpn: vpn,
            profile: PreviewSamples.subscriptionProfile,
            node: PreviewSamples.japan
        )
        ProfileNodeRow(
            vpn: vpn,
            profile: PreviewSamples.subscriptionProfile,
            node: PreviewSamples.singapore
        )
        ProfileNodeRow(
            vpn: vpn,
            profile: PreviewSamples.subscriptionProfile,
            node: PreviewSamples.losAngeles
        )
    }
}

#Preview("延迟徽章") {
    List {
        LabeledContent("未测试") { LatencyBadge(state: .untested) }
        LabeledContent("测试中") { LatencyBadge(state: .testing) }
        LabeledContent("良好") { LatencyBadge(state: .value(38)) }
        LabeledContent("一般") { LatencyBadge(state: .value(180)) }
        LabeledContent("较差") { LatencyBadge(state: .value(420)) }
        LabeledContent("超时") { LatencyBadge(state: .failed) }
    }
}

// MARK: - Detail

#Preview("策略组详情 · 手动选择") {
    NavigationStack {
        ClashGroupDetailView(
            vpn: .preview(
                latencyResults: PreviewSamples.latencyResults(forProfile: PreviewSamples.profileID)
            ),
            profileID: PreviewSamples.profileID,
            group: PreviewSamples.groups[0]
        )
    }
}

#Preview("策略组详情 · 自动选择") {
    NavigationStack {
        ClashGroupDetailView(
            vpn: .preview(
                latencyResults: PreviewSamples.latencyResults(forProfile: PreviewSamples.profileID)
            ),
            profileID: PreviewSamples.profileID,
            group: PreviewSamples.groups[1]
        )
    }
}

#Preview("配置详情") {
    ProfileDetailView(vpn: .preview(), profileID: PreviewSamples.profileID)
}

#Preview("兼容提示") {
    NavigationStack {
        ProfileCompatibility(profile: PreviewSamples.subscriptionProfile)
    }
}
#endif
