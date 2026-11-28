import SwiftUI

struct ProfileDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let vpn: PrototypeVPN
    let profileID: UUID

    @State private var draftName = ""
    @State private var draftURL = ""
    @State private var showsURLError = false
    @State private var showingDelete = false
    @State private var refreshingCustom = false
    @State private var customRefreshError: String?

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
                                .disabled(trimmedName.isEmpty || vpn.busy || vpn.switchingProfile)
                        }
                    }

                    if profile.resolvedEngine == .clash {
                        Section("配置内容") {
                            if let recipe = profile.customRecipe {
                                NavigationLink("编辑自定义配置") {
                                    CustomProfileBuilderView(vpn: vpn, profileID: profile.id)
                                }
                                .disabled(!vpn.canUpdateProfile(profile.id))
                                if recipe.sourcesChanged(in: vpn.library.profiles) {
                                    Text("来源已更新或不可用，请重新生成配置。")
                                        .font(.footnote).foregroundStyle(.orange)
                                }
                                Button {
                                    refreshingCustom = true
                                    customRefreshError = nil
                                    Task {
                                        do { try await vpn.refreshCustomProfile(profile.id) }
                                        catch { customRefreshError = error.localizedDescription }
                                        refreshingCustom = false
                                    }
                                } label: {
                                    if refreshingCustom { ProgressView() }
                                    else { Label("从来源重新生成", systemImage: "arrow.clockwise") }
                                }
                                .disabled(refreshingCustom || !vpn.canUpdateProfile(profile.id))
                                if let customRefreshError {
                                    Text(customRefreshError).font(.footnote).foregroundStyle(.red)
                                }
                            }
                            NavigationLink("查看和编辑 YAML") {
                                ConfigurationEditorView(vpn: vpn, profileID: profile.id)
                            }
                            .disabled(!vpn.canUpdateProfile(profile.id))
                            NavigationLink("配置覆写") {
                                ConfigurationOverridesView(vpn: vpn, profileID: profile.id)
                            }
                            Text("订阅更新会覆盖原文中的本地修改，覆写会保留。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }

                    Section("当前配置") {
                        LabeledContent("节点", value: profile.selectedOutboundName ?? "未选择")
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
                            TextField("订阅 URL", text: $draftURL, axis: .vertical)
                                .keyboardType(.URL)
                                .textContentType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .lineLimit(2...5)
                                .accessibilityIdentifier("profile-detail-url")
                                .disabled(!vpn.canUpdateProfile(profile.id))
                                .onChange(of: draftURL) {
                                    if RemoteImport.url(from: draftURL) != nil { showsURLError = false }
                                }
                            if showsURLError {
                                Text("请检查订阅链接的地址，并使用 HTTPS。")
                                    .font(.footnote).foregroundStyle(.red)
                            } else {
                                Text("修改链接后点击更新订阅；获取成功后保存新链接。")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
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
                                .disabled(vpn.busy || vpn.switchingProfile)
                            Picker("自动更新间隔", selection: Binding(
                                get: { profile.updateIntervalOverrideHours ?? 0 },
                                set: { vpn.setUpdateInterval($0 == 0 ? nil : $0, for: profile.id) }
                            )) {
                                Text("跟随订阅（默认 24 小时）").tag(0)
                                Text("6 小时").tag(6)
                                Text("12 小时").tag(12)
                                Text("24 小时").tag(24)
                                Text("3 天").tag(72)
                                Text("7 天").tag(168)
                            }.disabled(vpn.busy || vpn.switchingProfile || !profile.autoUpdateEnabled)
                            if profile.autoUpdateEnabled {
                                if let next = profile.nextAutoUpdateDate {
                                    LabeledContent(
                                        "下次可自动更新",
                                        value: next.formatted(date: .abbreviated, time: .shortened)
                                    )
                                }
                                Text("到期后，下次在 VPN 已断开时打开 App 或回到前台会尝试更新。")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            Button {
                                guard let url = RemoteImport.url(from: draftURL) else {
                                    showsURLError = true
                                    return
                                }
                                Task {
                                    await vpn.update(profile, sourceURL: url)
                                    if let savedURL = self.profile?.sourceURL, savedURL == url {
                                        draftURL = savedURL.absoluteString
                                    }
                                }
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
                            .disabled(!vpn.canUpdateProfile(profile.id))
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
                        ProfileShareLink(profile: profile) {
                            Label(
                                ProfileShare.actionTitle(for: profile),
                                systemImage: "square.and.arrow.up"
                            )
                        }
                        .accessibilityIdentifier("profile-detail-share")
                        NavigationLink("兼容提示") {
                            ProfileCompatibility(profile: profile)
                        }
                        Button("删除配置", role: .destructive) {
                            showingDelete = true
                        }
                        .disabled(!vpn.canRemoveProfile(profile.id))
                    } footer: {
                        Text(
                            profile.sourceURL != nil
                                ? "分享将发送订阅链接，链接可能包含订阅令牌，请仅分享给信任的人。"
                                : "分享将导出该配置的 YAML 文件，内容可能包含节点密码，请仅分享给信任的人。"
                        )
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
                draftURL = profile?.sourceURL?.absoluteString ?? ""
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
        .toast(vpn.toast)
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
