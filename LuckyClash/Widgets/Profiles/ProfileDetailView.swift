import SwiftUI

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

#if DEBUG
#Preview("配置详情") {
    ProfileDetailView(vpn: .preview(), profileID: PreviewSamples.profileID)
}
#endif
