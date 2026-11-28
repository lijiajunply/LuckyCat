import SwiftUI

struct CustomProfileBuilderView: View {
    let vpn: PrototypeVPN
    var profileID: UUID? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selectedProfiles: Set<UUID> = []
    @State private var manualLinks = ""
    @State private var sources: [CustomProfileDraft.Source] = []
    @State private var loadedProfiles: Set<UUID> = []
    @State private var loadedRevisions: [UUID: UUID] = [:]
    @State private var loadedManualLinks = ""
    @State private var inventory = CustomProfileDraft.Inventory()
    @State private var groups: [CustomProfileDraft.Group] = []
    @State private var groupName = ""
    @State private var editingGroupID: UUID?
    @State private var groupType = "select"
    @State private var selectedMembers: Set<String> = []
    @State private var selectedProviders: Set<String> = []
    @State private var testURL = ClashLatencyTester.defaultTestURL
    @State private var rules: [String] = []
    @State private var ruleType = "DOMAIN-SUFFIX"
    @State private var ruleValue = ""
    @State private var ruleTarget = "DIRECT"
    @State private var editingRuleIndex: Int?
    @State private var error: String?
    @State private var initialized = false
    @State private var saving = false

    private var missingProfiles: Set<UUID> {
        selectedProfiles.subtracting(vpn.library.profiles.map(\.id))
    }

    private var sourcesAreCurrent: Bool {
        guard !sources.isEmpty, loadedProfiles == selectedProfiles, loadedManualLinks == manualLinks else { return false }
        let current = vpn.library.profiles.filter { selectedProfiles.contains($0.id) }
        guard current.count == selectedProfiles.count else { return false }
        return current.allSatisfy { $0.clashRevision == loadedRevisions[$0.id] }
    }

    var body: some View {
        Form {
            Section("配置") {
                TextField("名称", text: $name)
                ForEach(vpn.library.profiles.filter { $0.resolvedEngine == .clash && $0.id != profileID }) { profile in
                    Toggle(profile.name, isOn: Binding(
                        get: { selectedProfiles.contains(profile.id) },
                        set: { if $0 { selectedProfiles.insert(profile.id) } else { selectedProfiles.remove(profile.id) } }
                    ))
                }
                if !missingProfiles.isEmpty {
                    Text("部分来源配置已删除，请移除后重新加载。")
                        .font(.footnote).foregroundStyle(.orange)
                    Button("移除缺失的来源") { selectedProfiles.subtract(missingProfiles) }
                }
                TextField("手动节点分享链接，每行一个", text: $manualLinks, axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("加载所选节点") { loadSources() }
                Text("节点和 Provider 从所选配置生成快照。")
                    .font(.footnote).foregroundStyle(.secondary)
                if !sources.isEmpty && !sourcesAreCurrent {
                    Text("来源已更改，请重新加载节点后保存。")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }
            if !sources.isEmpty {
                Section(LocalizedStringKey(editingGroupID == nil ? "添加策略组" : "编辑策略组")) {
                    TextField("策略组名称", text: $groupName)
                        .disabled(editingGroupID != nil)
                    Picker("类型", selection: $groupType) {
                        ForEach(["select", "url-test", "fallback", "load-balance"], id: \.self) { Text($0).tag($0) }
                    }
                    if groupType != "select" {
                        TextField("测速地址", text: $testURL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    ForEach(inventory.proxyNames + groups.filter { $0.id != editingGroupID }.map(\.name) + ["DIRECT", "REJECT"], id: \.self) { member in
                        Toggle(member, isOn: membership(member, in: $selectedMembers))
                    }
                    ForEach(inventory.proxyProviders.keys.sorted(), id: \.self) { provider in
                        Toggle("Provider · \(provider)", isOn: membership(provider, in: $selectedProviders))
                    }
                    Button(LocalizedStringKey(editingGroupID == nil ? "添加策略组" : "保存策略组")) { addGroup() }
                    if editingGroupID != nil { Button("取消编辑") { resetGroupEditor() } }
                }
                if !groups.isEmpty {
                    Section("策略组") {
                        ForEach(groups) { group in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(group.name)
                                    Text("\(group.type) · \((group.members + group.providers).joined(separator: "、"))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("编辑") { editGroup(group) }.buttonStyle(.borderless)
                            }
                        }
                        .onDelete { offsets in
                            if let editingGroupID, offsets.contains(where: { groups[$0].id == editingGroupID }) { resetGroupEditor() }
                            groups.remove(atOffsets: offsets)
                        }
                        .onMove { groups.move(fromOffsets: $0, toOffset: $1) }
                    }
                    Section(LocalizedStringKey(editingRuleIndex == nil ? "添加规则" : "编辑规则")) {
                        Picker("类型", selection: $ruleType) {
                            ForEach(["DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "IP-CIDR", "IP-CIDR6", "GEOIP", "GEOSITE", "RULE-SET", "MATCH"], id: \.self) {
                                Text($0).tag($0)
                            }
                        }
                        if ruleType != "MATCH" { TextField("匹配内容", text: $ruleValue).autocorrectionDisabled() }
                        Picker("策略", selection: $ruleTarget) {
                            ForEach(["DIRECT", "REJECT"] + groups.map(\.name), id: \.self) { Text($0).tag($0) }
                        }
                        Button(LocalizedStringKey(editingRuleIndex == nil ? "添加规则" : "保存规则")) { addRule() }
                        if editingRuleIndex != nil { Button("取消编辑") { resetRuleEditor() } }
                    }
                    Section("规则顺序") {
                        ForEach(Array(rules.enumerated()), id: \.offset) { index, rule in
                            HStack {
                                Text(rule).font(.caption.monospaced())
                                Spacer()
                                Button("编辑") { editRule(index) }.buttonStyle(.borderless)
                            }
                        }
                        .onDelete { rules.remove(atOffsets: $0); resetRuleEditor() }
                        .onMove { rules.move(fromOffsets: $0, toOffset: $1); resetRuleEditor() }
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("自定义配置")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }
                    .disabled(saving || vpn.busy || vpn.switchingProfile || groups.isEmpty || !sourcesAreCurrent || editingGroupID != nil || editingRuleIndex != nil || (profileID.map { !vpn.canUpdateProfile($0) } ?? false))
            }
        }
        .task { restoreRecipe() }
    }

    private func membership(_ value: String, in selection: Binding<Set<String>>) -> Binding<Bool> {
        Binding(get: { selection.wrappedValue.contains(value) }, set: {
            if $0 { selection.wrappedValue.insert(value) } else { selection.wrappedValue.remove(value) }
        })
    }

    private func loadSources() {
        do {
            guard missingProfiles.isEmpty else {
                throw CustomProfileDraft.Failure.invalid("部分来源配置已删除，请移除后重新加载。")
            }
            let recipe = CustomProfileRecipe(sourceProfileIDs: selectedProfiles.sorted { $0.uuidString < $1.uuidString },
                                             manualLinks: manualLinks, groups: groups, rules: rules)
            let resolved = try CustomProfileDraft.resolveSources(recipe: recipe, profiles: vpn.library.profiles,
                                                                 excluding: profileID, load: vpn.configurationText)
            inventory = resolved.inventory
            sources = resolved.sources
            loadedProfiles = selectedProfiles
            loadedRevisions = resolved.revisions
            loadedManualLinks = manualLinks
            resetGroupEditor()
            resetRuleEditor()
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func addGroup() {
        let name = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        let order = inventory.proxyNames + groups.filter { $0.id != editingGroupID }.map(\.name) + ["DIRECT", "REJECT"]
        guard !name.isEmpty, !groups.contains(where: { $0.name == name && $0.id != editingGroupID }),
              !inventory.proxyNames.contains(name), !["DIRECT", "REJECT", "GLOBAL"].contains(name),
              !name.contains(","), !name.contains(where: \.isNewline),
              !selectedMembers.isEmpty || !selectedProviders.isEmpty,
              selectedMembers.isSubset(of: Set(order)),
              selectedProviders.isSubset(of: Set(inventory.proxyProviders.keys)) else {
            error = "请输入唯一名称并选择有效成员；来源变更后请重新选择成员。"
            return
        }
        let group = CustomProfileDraft.Group(name: name, type: groupType, members: order.filter(selectedMembers.contains),
                                             providers: selectedProviders.sorted(), testURL: testURL)
        if let editingGroupID, let index = groups.firstIndex(where: { $0.id == editingGroupID }) {
            groups[index] = group
        } else { groups.append(group) }
        resetGroupEditor()
        error = nil
    }

    private func editGroup(_ group: CustomProfileDraft.Group) {
        editingGroupID = group.id
        groupName = group.name
        groupType = group.type
        let available = Set(inventory.proxyNames + groups.filter { $0.id != group.id }.map(\.name) + ["DIRECT", "REJECT"])
        selectedMembers = Set(group.members).intersection(available)
        selectedProviders = Set(group.providers).intersection(inventory.proxyProviders.keys)
        error = selectedMembers.count != group.members.count || selectedProviders.count != group.providers.count
            ? "来源已更改，部分成员不可用，请重新选择。" : nil
        testURL = group.testURL
    }

    private func resetGroupEditor() {
        editingGroupID = nil
        groupName = ""
        selectedMembers = []
        selectedProviders = []
    }

    private func addRule() {
        let value = ruleValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard groups.contains(where: { $0.name == ruleTarget }) || ["DIRECT", "REJECT"].contains(ruleTarget),
              ruleType == "MATCH" || (!value.isEmpty && !value.contains(",") && !value.contains(where: \.isNewline)) else {
            error = "请输入有效的规则内容和策略。"
            return
        }
        let rule = ruleType == "MATCH" ? "MATCH,\(ruleTarget)" : "\(ruleType),\(value),\(ruleTarget)"
        if let index = editingRuleIndex, rules.indices.contains(index) { rules[index] = rule }
        else { rules.append(rule) }
        resetRuleEditor()
        error = nil
    }

    private func editRule(_ index: Int) {
        let parts = rules[index].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return }
        editingRuleIndex = index
        ruleType = parts[0]
        ruleValue = parts.count == 3 ? parts[1] : ""
        ruleTarget = parts.last ?? "DIRECT"
    }

    private func resetRuleEditor() {
        editingRuleIndex = nil
        ruleValue = ""
    }

    private func save() {
        do {
            guard sourcesAreCurrent else { throw CustomProfileDraft.Failure.invalid("来源已更改，请重新加载节点。") }
            let yaml = try CustomProfileDraft.build(inventory: inventory, groups: groups, rules: rules)
            let resolvedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let savedName = resolvedName.isEmpty ? "自定义配置" : String(resolvedName.prefix(80))
            let recipe = CustomProfileRecipe(sourceProfileIDs: selectedProfiles.sorted { $0.uuidString < $1.uuidString },
                                             manualLinks: manualLinks, groups: groups, rules: rules,
                                             sourceRevisions: loadedRevisions)
            if let profileID {
                guard let profile = vpn.library.profiles.first(where: { $0.id == profileID }) else {
                    throw CustomProfileDraft.Failure.invalid("配置已删除。")
                }
                saving = true
                Task {
                    if await vpn.saveConfiguration(yaml, for: profile, customRecipe: recipe, name: savedName) {
                        dismiss()
                    } else {
                        error = vpn.message ?? "无法保存配置。"
                    }
                    saving = false
                }
            } else {
                vpn.stage(Data(yaml.utf8))
                guard vpn.hasStagedImport else { throw CustomProfileDraft.Failure.invalid(vpn.importError ?? "无法读取生成的配置。") }
                guard vpn.saveImport(named: savedName, selectedNode: vpn.imported.first?.id ?? "", customRecipe: recipe) else {
                    throw CustomProfileDraft.Failure.invalid(vpn.importError ?? "无法保存配置。")
                }
                dismiss()
            }
        } catch { self.error = error.localizedDescription }
    }

    private func restoreRecipe() {
        guard !initialized else { return }
        initialized = true
        guard let profileID else { return }
        guard let profile = vpn.library.profiles.first(where: { $0.id == profileID }),
              let recipe = profile.customRecipe else {
            error = "无法读取自定义配置的编辑信息。"
            return
        }
        name = profile.name
        selectedProfiles = Set(recipe.sourceProfileIDs)
        manualLinks = recipe.manualLinks
        groups = recipe.groups
        rules = recipe.rules
        loadSources()
    }
}
