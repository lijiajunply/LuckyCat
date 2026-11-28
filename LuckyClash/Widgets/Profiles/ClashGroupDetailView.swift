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
            if let profile {
                Section {
                    LabeledContent("类型", value: group.type)
                    LabeledContent("成员", value: "\(vpn.members(for: group, profileID: profile.id).count)")
                    let chain = vpn.strategyChain(from: group.name, profile: profile)
                    if chain.count > 1 {
                        LabeledContent("当前策略", value: chain.joined(separator: " → "))
                    }
                    if group.canPin, let fixed = vpn.fixedMember(in: group.name, profile: profile) {
                        Button("已固定 \(fixed)，恢复自动选择", systemImage: "pin.slash") {
                            vpn.unfixGroup(profileID: profile.id, group: group)
                        }
                        .disabled(!vpn.canSwitchNodes(for: profile.id))
                    }
                }
                Section("成员") {
                    if vpn.members(for: group, profileID: profile.id).isEmpty {
                        Text("该策略组暂无成员。").foregroundStyle(.secondary)
                    }
                    ForEach(vpn.members(for: group, profileID: profile.id), id: \.self) { member in
                        StrategyMemberRow(vpn: vpn, profile: profile, group: group, name: member)
                    }
                }
            }
        }
        .navigationTitle(group.name)
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
