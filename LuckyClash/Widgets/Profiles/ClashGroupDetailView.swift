import SwiftUI

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
                    Text("切换后是否关闭已有连接可在设置中调整。")
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
            LatencyBadge(state: vpn.latencyState(for: member, profileID: profile.id, testURL: PrototypeVPN.normalizedTestURL(group.testURL)))
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

#if DEBUG
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
#endif
