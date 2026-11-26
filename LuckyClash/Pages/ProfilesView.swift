import SwiftUI
import NetworkExtension

struct ProfilesView: View {
    let vpn: PrototypeVPN
    var onShowDetail: (UUID) -> Void
    var onDelete: (Profile) -> Void
    var onShowConnection: () -> Void
    var onShowInfo: () -> Void

    @State private var expandedGroups: Set<String> = []

    private var profile: Profile? { vpn.library.selectedProfile }

    var body: some View {
        NavigationStack {
            List {
                if let profile {
                    if let groups = profile.clashGroups, !groups.isEmpty {
                        groupsSection(profile: profile, groups: groups)
                    }
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
            .task(id: "\(vpn.status.rawValue)-\(profile?.id.uuidString ?? "")") { await vpn.refreshLiveGroups() }
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
                Button {
                    if expandedGroups.contains(group.name) {
                        expandedGroups.remove(group.name)
                    } else {
                        expandedGroups.insert(group.name)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: expandedGroups.contains(group.name) ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.name).foregroundStyle(.primary)
                            Text("\(group.type) · \(vpn.members(for: group).count) 个成员")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if profile.clashGroup == group.name {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                                .accessibilityLabel("当前策略组")
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu { groupLatencyAction(group) }
                .swipeActions(edge: .trailing) { groupLatencyAction(group) }

                if expandedGroups.contains(group.name) {
                    if vpn.members(for: group).isEmpty {
                        Text("该策略组暂无成员。").foregroundStyle(.secondary)
                    }
                    ForEach(vpn.members(for: group), id: \.self) { member in
                        if let node = profile.nodes.first(where: { $0.name == member }) {
                            ProfileNodeRow(vpn: vpn, profile: profile, node: node, group: group)
                                .padding(.leading, 20)
                        } else {
                            Button {
                                vpn.selectMember(profileID: profile.id, group: group, member: member)
                            } label: {
                                HStack {
                                    Text(member).foregroundStyle(.primary)
                                    Spacer()
                                    LatencyBadge(state: vpn.latencyState(for: member, profileID: profile.id, testURL: PrototypeVPN.normalizedTestURL(group.testURL)))
                                    if profile.clashGroup == group.name && profile.clashSelectedMember == member {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }.contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!group.isSelectable || !vpn.canSwitchNodes(for: profile.id))
                            .padding(.leading, 20)
                        }
                    }
                    if !group.isSelectable {
                        Text("该策略组由内核自动选择，不能手动切换。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("策略组")
        }
    }

    private func groupLatencyAction(_ group: ClashImportGroup) -> some View {
        Button {
            Task { await vpn.testLatency(nodeNames: vpn.members(for: group), testURL: PrototypeVPN.normalizedTestURL(group.testURL)) }
        } label: {
            Label("测试组内延迟", systemImage: "speedometer")
        }
        .disabled(vpn.busy || vpn.latencyTesting)
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
                Text("切换后是否关闭已有连接可在设置中调整。")
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
#endif
