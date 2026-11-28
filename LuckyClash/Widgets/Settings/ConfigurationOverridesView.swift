import SwiftUI

struct ConfigurationOverridesView: View {
    let vpn: PrototypeVPN
    var profileID: UUID?
    @State private var draft = ConfigurationOverrides.empty
    @State private var saving = false
    @State private var error: String?
    @State private var showPreview = false
    @State private var preview = ""
    @State private var textInputs: [String: String] = [:]

    private var profile: Profile? {
        if let profileID { return vpn.library.profiles.first { $0.id == profileID } }
        return vpn.library.selectedProfile
    }

    var body: some View {
        Form {
            Section("DNS") {
                Picker("增强模式", selection: $draft.dnsMode) {
                    Text("继承").tag(nil as ConfigurationOverrides.DNSMode?)
                    ForEach(ConfigurationOverrides.DNSMode.allCases, id: \.self) {
                        Text($0.rawValue).tag(Optional($0))
                    }
                }
                TextField("Nameserver，每行一个", text: lines("nameservers", \.nameservers), axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Fallback，每行一个", text: lines("fallback", \.fallback), axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Fake-IP Filter，每行一个", text: lines("fakeIPFilter", \.fakeIPFilter), axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                policy("遵从规则", selection: $draft.dnsRespectRules)
                policy("IPv6", selection: $draft.dnsIPv6)
                TextField("Hosts，每行一个域名=IP", text: hosts, axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Section("附加规则") {
                TextField("前置规则，每行一条", text: rules("prependRules", \.prependRules), axis: .vertical)
                TextField("追加规则，每行一条", text: rules("appendRules", \.appendRules), axis: .vertical)
                Text("例如 DOMAIN-SUFFIX,example.com,DIRECT。规则按顺序匹配，MATCH 会结束匹配。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("内核功能") {
                policy("流量嗅探", selection: $draft.sniffer)
                policy("NTP", selection: $draft.ntp)
            }
            Section {
                if let profile {
                    Button("预览最终 YAML", systemImage: "doc.text.magnifyingglass") { showYAML(profile) }
                    NavigationLink("浏览与模拟规则") {
                        RulesInspectorView(vpn: vpn, profileID: profile.id)
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle(profileID == nil ? "全局覆写" : "配置覆写")
        .onAppear {
            draft = profileID == nil ? (vpn.library.overrides ?? .empty) : (profile?.overrides ?? .empty)
        }
        .toolbar {
            Button("保存") {
                saving = true
                Task {
                    defer { saving = false }
                    do {
                        try await vpn.saveOverrides(draft, profileID: profileID)
                        error = nil
                    } catch { self.error = error.localizedDescription }
                }
            }
            .disabled(saving || vpn.busy || vpn.switchingProfile)
        }
        .sheet(isPresented: $showPreview) {
            NavigationStack {
                ScrollView {
                    Text(preview).font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle("生效 YAML")
                .toolbar { Button("完成") { showPreview = false } }
            }
        }
    }

    private func policy(_ title: String, selection: Binding<Bool?>) -> some View {
        Picker(title, selection: selection) {
            Text("继承").tag(nil as Bool?)
            Text("开启").tag(Optional(true))
            Text("关闭").tag(Optional(false))
        }
    }

    private func lines(_ id: String, _ key: WritableKeyPath<ConfigurationOverrides, [String]?>) -> Binding<String> {
        Binding {
            textInputs[id] ?? draft[keyPath: key]?.joined(separator: "\n") ?? ""
        } set: { input in
            textInputs[id] = input
            let entries = Self.entries(input)
            draft[keyPath: key] = entries.isEmpty ? nil : entries
        }
    }

    private func rules(_ id: String, _ key: WritableKeyPath<ConfigurationOverrides, [String]>) -> Binding<String> {
        Binding {
            textInputs[id] ?? draft[keyPath: key].joined(separator: "\n")
        } set: { input in
            textInputs[id] = input
            draft[keyPath: key] = Self.entries(input)
        }
    }

    @State private var hostsInput: String?
    private var hosts: Binding<String> {
        Binding {
            hostsInput ?? draft.hosts?.sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\($0.value)" }.joined(separator: "\n") ?? ""
        } set: { input in
            hostsInput = input
            var result: [String: String] = [:]
            for line in Self.entries(input) {
                let fields = line.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if fields.count == 2, !fields[0].isEmpty, !fields[1].isEmpty {
                    result[fields[0]] = fields[1]
                }
            }
            draft.hosts = result.isEmpty ? nil : result
        }
    }

    private static func entries(_ input: String) -> [String] {
        input.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func showYAML(_ profile: Profile) {
        do {
            let raw = try vpn.configurationText(for: profile)
            let yaml = try ClashOverridePipeline.compose(
                raw,
                global: profileID == nil ? draft : (vpn.library.overrides ?? .empty),
                profile: profileID == nil ? (profile.overrides ?? .empty) : draft
            )
            preview = ClashModeOverride.apply(vpn.library.trafficMode, to: yaml)
            showPreview = true
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
