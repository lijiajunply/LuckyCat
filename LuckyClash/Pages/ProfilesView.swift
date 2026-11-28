import SwiftUI
import NetworkExtension

struct ProfilesView: View {
    let vpn: PrototypeVPN
    var onShowDetail: (UUID) -> Void
    var onDelete: (Profile) -> Void
    var onShowConnection: () -> Void
    var onShowInfo: () -> Void

    private enum SortOrder: String, CaseIterable {
        case configuration = "配置顺序"
        case latency = "延迟升序"
        case name = "名称"
    }

    @AppStorage("strategyGroupTabs") private var usesTabs = false
    @AppStorage("nodeGridLayout") private var usesGrid = false
    @AppStorage("hideTimedOutNodes") private var hidesTimedOut = false
    @AppStorage("nodeSortOrder") private var sortOrder = SortOrder.configuration
    @State private var expandedGroups: Set<String> = []
    @State private var selectedGroup: String?
    @State private var testingGroup: String?
    @State private var query = ""

    private var profile: Profile? { vpn.library.selectedProfile }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
                List {
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
                .searchable(text: $query, prompt: "搜索节点或策略组")
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
                            displayOptions(profile, scroll: scroll)

                            ProfileShareLink(profile: profile) {
                                Image(systemName: "square.and.arrow.up")
                                    .accessibilityLabel(ProfileShare.actionTitle(for: profile))
                            }
                            .accessibilityIdentifier("share-profile-\(profile.name)")
                            Button {
                                onShowDetail(profile.id)
                            } label: {
                                Image(systemName: "square.and.pencil")
                                    .accessibilityLabel("详情与编辑")
                            }
                            .disabled(vpn.busy || vpn.switchingProfile)
                            Button(role: .destructive) {
                                onDelete(profile)
                            } label: {
                                Image(systemName: "trash")
                                    .accessibilityLabel("删除配置")
                            }
                            .accessibilityIdentifier("delete-profile-\(profile.name)")
                            .disabled(!vpn.canRemoveProfile(profile.id))
                        }
                    }
                }
            }
        }
    }

    private func displayOptions(_ profile: Profile, scroll: ScrollViewProxy) -> some View {
        Menu {
            Picker("排序", selection: $sortOrder) {
                ForEach(SortOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Toggle("隐藏超时节点", isOn: $hidesTimedOut)
            Toggle("策略组标签", isOn: $usesTabs)
            Toggle("紧凑节点网格", isOn: $usesGrid)
            Button("定位当前节点", systemImage: "scope") {
                query = ""
                hidesTimedOut = false
                let group = profile.clashGroup ?? profile.clashGroups?.first?.name
                let member = group.flatMap { vpn.selectedMember(in: $0, profile: profile) }
                let target: [String]
                if let group, let member {
                    selectedGroup = group
                    expandedGroups.insert(group)
                    target = rowID(member, group: group)
                } else if let name = profile.selectedNode?.name {
                    target = rowID(name, group: nil)
                } else { return }
                Task { @MainActor in
                    await Task.yield()
                    withAnimation { scroll.scrollTo(target, anchor: .center) }
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .accessibilityLabel("节点显示选项")
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
                .disabled(vpn.busy || vpn.switchingProfile)
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
            .disabled(!vpn.canUpdateProfile(profile.id))
        } header: {
            Text("订阅")
        }
    }

    private func groupsSection(profile: Profile, groups: [ClashImportGroup]) -> some View {
        let matching = groups.filter { matches($0.name) || vpn.members(for: $0, profileID: profile.id).contains(where: matches) }
        let shown = matching.first { $0.name == selectedGroup } ?? matching.first
        return Section("策略组") {
            if matching.isEmpty {
                Text("没有匹配的策略组。").foregroundStyle(.secondary)
            } else if usesTabs, let shown {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(matching, id: \.name) { group in
                            Button(group.name) { selectedGroup = group.name }
                                .buttonStyle(.bordered)
                                .tint(group.name == shown.name ? .accentColor : .secondary)
                                .accessibilityAddTraits(group.name == shown.name ? .isSelected : [])
                        }
                    }
                }
                groupHeader(shown, profile: profile, expanded: nil)
                groupRows(shown, profile: profile)
            } else {
                ForEach(matching, id: \.name) { group in
                    let expanded = expandedGroups.contains(group.name) || !query.isEmpty
                    groupHeader(group, profile: profile, expanded: expanded)
                    if expanded { groupRows(group, profile: profile) }
                }
            }
        }
    }

    private func groupHeader(_ group: ClashImportGroup, profile: Profile, expanded: Bool?) -> some View {
        HStack(spacing: 12) {
            if let expanded {
                Button {
                    if expandedGroups.contains(group.name) { expandedGroups.remove(group.name) }
                    else { expandedGroups.insert(group.name) }
                } label: {
                    groupTitle(group, profile: profile, chevron: expanded ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.plain)
            } else {
                groupTitle(group, profile: profile, chevron: nil)
            }
            if testingGroup == group.name {
                ProgressView().accessibilityLabel("正在测试组内延迟")
            } else {
                Button {
                    testingGroup = group.name
                    Task {
                        defer { testingGroup = nil }
                        await vpn.testLatency(
                            nodeNames: vpn.members(for: group, profileID: profile.id),
                            testURL: PrototypeVPN.normalizedTestURL(group.testURL)
                        )
                    }
                } label: {
                    Image(systemName: "speedometer").accessibilityLabel("测试组内延迟")
                }
                .buttonStyle(.borderless)
                .disabled(vpn.busy || vpn.latencyTesting || vpn.switchingProfile)
            }
        }
    }

    private func groupTitle(_ group: ClashImportGroup, profile: Profile, chevron: String?) -> some View {
        HStack(spacing: 8) {
            if let chevron { Image(systemName: chevron).font(.caption).foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name).foregroundStyle(.primary)
                let chain = vpn.strategyChain(from: group.name, profile: profile)
                let detail = chain.count > 1
                    ? chain.dropFirst().joined(separator: " → ")
                    : (group.type == "load-balance" ? "按连接分配" : group.type)
                Text("\(detail) · \(vpn.members(for: group, profileID: profile.id).count) 个成员")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private func groupRows(_ group: ClashImportGroup, profile: Profile) -> some View {
        if group.canPin, let fixed = vpn.fixedMember(in: group.name, profile: profile) {
            Button("已固定 \(fixed)，恢复自动选择", systemImage: "pin.slash") {
                vpn.unfixGroup(profileID: profile.id, group: group)
            }
            .disabled(!vpn.canSwitchNodes(for: profile.id))
        }
        let names = visibleNames(
            vpn.members(for: group, profileID: profile.id), profile: profile, group: group,
            includeAll: !query.isEmpty && matches(group.name)
        )
        memberRows(names, profile: profile, group: group)
    }

    private func nodesSection(_ profile: Profile) -> some View {
        Section("节点") {
            memberRows(visibleNames(profile.nodes.map(\.name), profile: profile), profile: profile, group: nil)
        }
    }

    @ViewBuilder private func memberRows(_ names: [String], profile: Profile, group: ClashImportGroup?) -> some View {
        if names.isEmpty {
            Text("没有符合条件的节点。").foregroundStyle(.secondary)
        } else if usesGrid {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 8)], spacing: 8) {
                ForEach(names, id: \.self) { member in
                    memberRow(member, profile: profile, group: group)
                        .padding(8)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        } else {
            ForEach(names, id: \.self) { member in
                memberRow(member, profile: profile, group: group)
            }
        }
    }

    @ViewBuilder private func memberRow(_ member: String, profile: Profile, group: ClashImportGroup?) -> some View {
        if let node = profile.nodes.first(where: { $0.name == member }) {
            ProfileNodeRow(vpn: vpn, profile: profile, node: node, group: group)
                .id(rowID(member, group: group?.name))
        } else if let group {
            StrategyMemberRow(vpn: vpn, profile: profile, group: group, name: member)
                .id(rowID(member, group: group.name))
        }
    }

    private func visibleNames(
        _ names: [String], profile: Profile, group: ClashImportGroup? = nil, includeAll: Bool = false
    ) -> [String] {
        let testURL = group.map { PrototypeVPN.normalizedTestURL($0.testURL) }
        var seen: Set<String> = []
        let filtered = names.filter { name in
            seen.insert(name).inserted && (includeAll || matches(name))
                && (!hidesTimedOut || vpn.latencyState(for: name, profileID: profile.id, testURL: testURL) != .failed)
        }
        switch sortOrder {
        case .configuration: return filtered
        case .name: return filtered.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        case .latency:
            return filtered.sorted { first, second in
                let lhs = vpn.latencyValue(for: first, profileID: profile.id, testURL: testURL) ?? Int.max
                let rhs = vpn.latencyValue(for: second, profileID: profile.id, testURL: testURL) ?? Int.max
                return lhs == rhs ? first.localizedStandardCompare(second) == .orderedAscending : lhs < rhs
            }
        }
    }

    private func matches(_ name: String) -> Bool {
        query.isEmpty || name.localizedStandardContains(query)
    }

    private func rowID(_ member: String, group: String?) -> [String] {
        group.map { [$0, member] } ?? [member]
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
