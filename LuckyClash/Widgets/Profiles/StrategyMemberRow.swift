import SwiftUI

struct StrategyMemberRow: View {
    let vpn: PrototypeVPN
    let profile: Profile
    let group: ClashImportGroup
    let name: String

    var body: some View {
        Button {
            vpn.selectMember(profileID: profile.id, group: group, member: name)
        } label: {
            HStack(spacing: 8) {
                Text(name).foregroundStyle(.primary)
                Spacer(minLength: 4)
                LatencyBadge(state: vpn.latencyState(
                    for: name, profileID: profile.id, testURL: PrototypeVPN.normalizedTestURL(group.testURL)
                ))
                if vpn.selectedMember(in: group.name, profile: profile) == name {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                        .accessibilityLabel("当前选择")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled((!group.isSelectable && !group.canPin) || !vpn.canSwitchNodes(for: profile.id))
    }
}
