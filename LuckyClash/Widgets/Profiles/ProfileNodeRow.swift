import SwiftUI

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
