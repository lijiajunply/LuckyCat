import SwiftUI

struct ProfileNodeRow: View {
    let vpn: PrototypeVPN
    let profile: Profile
    let node: Profile.Node
    var group: ClashImportGroup? = nil

    var body: some View {
        Button {
            guard vpn.canSwitchNodes(for: profile.id) else { return }
            vpn.select(profileID: profile.id, nodeID: node.id, group: group?.name)
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
                LatencyBadge(state: vpn.latencyState(for: node.name, profileID: profile.id, testURL: group.map { PrototypeVPN.normalizedTestURL($0.testURL) }))
                if group.map({ vpn.selectedMember(in: $0.name, profile: profile) == node.name })
                    ?? (profile.selectedOutboundName == node.name) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("当前节点")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(group.map { !$0.isSelectable && !$0.canPin } ?? false)
        .contextMenu { latencyAction }
        .swipeActions(edge: .trailing) { latencyAction }
        .accessibilityIdentifier("node-\(profile.name)-\(node.name)")
    }
    private var latencyAction: some View {
        Button {
            Task { await vpn.testLatency(nodeNames: [node.name], testURL: group.map { PrototypeVPN.normalizedTestURL($0.testURL) }) }
        } label: {
            Label("测试延迟", systemImage: "speedometer")
        }
        .disabled(vpn.busy || vpn.latencyTesting)
    }
}

#if DEBUG
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
#endif
