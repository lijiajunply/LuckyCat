import Clash
import NetworkExtension
import SwiftUI

struct RulesInspectorView: View {
    let vpn: PrototypeVPN
    let profileID: UUID

    @State private var type = ""
    @State private var query = ""
    @State private var target = ""
    @State private var result: String?
    @State private var testing = false
    @State private var hitsOnly = false
    @State private var offset = 0
    @State private var page: ClashRulePage?
    @State private var error: String?

    private let pageSize = 100
    private var profile: Profile? { vpn.library.profiles.first { $0.id == profileID } }
    private var live: Bool { vpn.status == .connected && vpn.isRunningProfile(profileID) }
    private var pageKey: [String] {
        [query, type, String(offset), String(hitsOnly), String(live), String(vpn.routeRevision),
         profile?.effectiveRevision?.uuidString ?? profile?.clashRevision?.uuidString ?? ""]
    }

    var body: some View {
        List {
            Section("模拟匹配") {
                TextField("域名或 IP", text: $target)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("模拟匹配", systemImage: "play.circle") {
                    Task { await simulate() }
                }
                .disabled(testing || target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if testing { ProgressView() }
                if let result { Text(result).textSelection(.enabled) }
            }
            Section("生效规则") {
                TextField("关键词", text: $query).disabled(hitsOnly)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("类型，例如 DOMAIN-SUFFIX", text: $type).disabled(hitsOnly)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                if live { Toggle("仅显示有命中记录的规则", isOn: $hitsOnly) }
                if let error { Text(error).foregroundStyle(.red) }
                if let page {
                    if page.rules.isEmpty { Text("没有符合条件的规则。").foregroundStyle(.secondary) }
                    ForEach(page.rules) { rule in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(rule.summary).textSelection(.enabled)
                            if let hits = rule.extra?.hitCount {
                                Text("命中 \(hits) 次").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    navigation(page)
                }
            }
        }
        .navigationTitle("规则")
        .onChange(of: query) { offset = 0 }
        .onChange(of: type) { offset = 0 }
        .onChange(of: hitsOnly) { offset = 0 }
        .onChange(of: target) { result = nil }
        .onChange(of: live) { if !live { hitsOnly = false } }
        .task(id: pageKey) { await load() }
        .refreshable { await load() }
    }

    private func navigation(_ page: ClashRulePage) -> some View {
        let count = page.noted ?? page.matched ?? page.total
        return HStack {
            Button("上一页") { offset -= pageSize }.disabled(offset == 0)
            Spacer()
            Text(count == 0 ? "0 条" : "\(offset + 1)–\(min(count, offset + pageSize)) / \(count)")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("下一页") { offset += pageSize }.disabled(offset + pageSize >= count)
        }
        .buttonStyle(.borderless)
    }

    private func load() async {
        guard let profile else { return }
        let key = pageKey
        let kind = type.trimmingCharacters(in: .whitespacesAndNewlines)
        let types = kind.isEmpty ? "" : String(decoding: (try? JSONEncoder().encode([kind])) ?? Data(), as: UTF8.self)
        do {
            let current: ClashRulePage
            if live && (query.isEmpty || hitsOnly) {
                current = try await vpn.live.rules(offset: offset, limit: pageSize, types: types, hits: hitsOnly)
            } else {
                let yaml = try vpn.effectiveConfiguration(for: profile)
                let catalog = try await Self.readRules(yaml, offset: offset, limit: pageSize, query: query, types: types)
                if live && !catalog.rules.isEmpty {
                    current = await addLiveStatistics(to: catalog, key: key)
                } else {
                    current = catalog
                }
            }
            guard !Task.isCancelled, key == pageKey else { return }
            page = current
            error = nil
        } catch {
            guard !Task.isCancelled, key == pageKey else { return }
            self.error = error.localizedDescription
            page = nil
        }
    }

    private func addLiveStatistics(to page: ClashRulePage, key: [String]) async -> ClashRulePage {
        // Fetch only the live windows containing the filtered catalog rows.
        // A failure leaves the filtered rules visible without stale counters.
        let windows = Set(page.rules.map { ($0.index / pageSize) * pageSize }).sorted()
        var liveRules: [Int: ClashRulePage.Rule] = [:]
        for window in windows {
            guard !Task.isCancelled, key == pageKey else { return page }
            guard let livePage = try? await vpn.live.rules(offset: window, limit: pageSize, types: "", hits: false) else {
                return page
            }
            for rule in livePage.rules { liveRules[rule.index] = rule }
        }
        return page.addingStatistics(liveRules)
    }

    @concurrent private static func readRules(
        _ yaml: String, offset: Int, limit: Int, query: String, types: String
    ) async throws -> ClashRulePage {
        var error: NSError?
        guard let catalog = ClashOpenRuleCatalogForIOS(yaml, &error) else {
            throw error ?? ClashImport.Failure.unreadable
        }
        defer { catalog.close() }
        return try ClashRulePage.decode(catalog.pageJSON(
            Int32(clamping: offset), limit: Int32(limit), query: query, target: nil, typesJSON: types
        ))
    }

    private func simulate() async {
        guard let profile else { return }
        let input = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let revision = profile.effectiveRevision ?? profile.clashRevision
        let route = vpn.routeRevision
        testing = true
        defer { testing = false }
        do {
            let yaml = try vpn.effectiveConfiguration(for: profile)
            let match = try await ClashLatencyTester.shared.simulateRule(
                yaml, host: input
            )
            guard !Task.isCancelled, input == target.trimmingCharacters(in: .whitespacesAndNewlines),
                  revision == (self.profile?.effectiveRevision ?? self.profile?.clashRevision),
                  route == vpn.routeRevision else { return }
            if match.matched {
                let root = match.policy ?? ""
                let route = vpn.strategyChain(from: root, profile: profile).joined(separator: " → ")
                result = [match.rule, route].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            } else if match.undecided == true {
                result = "无法确定匹配。\(match.reason ?? "")"
            } else {
                result = "未命中规则。"
            }
        } catch {
            guard !Task.isCancelled, input == target.trimmingCharacters(in: .whitespacesAndNewlines),
                  revision == (self.profile?.effectiveRevision ?? self.profile?.clashRevision),
                  route == vpn.routeRevision else { return }
            result = error.localizedDescription
        }
    }
}
