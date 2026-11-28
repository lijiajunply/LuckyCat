import Clash
import Foundation

/// The editable inputs used to generate a custom profile. The generated YAML
/// remains a snapshot until the user reloads the selected sources and saves.
struct CustomProfileRecipe: Codable {
    var sourceProfileIDs: [UUID]
    var manualLinks: String
    var groups: [CustomProfileDraft.Group]
    var rules: [String]
    // Optional for profiles created before source revision tracking.
    var sourceRevisions: [UUID: UUID]? = nil

    func sourcesChanged(in profiles: [Profile]) -> Bool {
        guard let sourceRevisions, sourceRevisions.count == sourceProfileIDs.count else { return !sourceProfileIDs.isEmpty }
        let byID = Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return sourceProfileIDs.contains { id in
            guard let revision = byID[id]?.clashRevision else { return true }
            return sourceRevisions[id] != revision
        }
    }

    mutating func remapSourceRevisions(original: [UUID: UUID], restored: [UUID: UUID]) {
        guard var revisions = sourceRevisions else { return }
        for (id, revision) in revisions where original[id] == revision {
            if let replacement = restored[id] { revisions[id] = replacement }
        }
        sourceRevisions = revisions
    }
}

struct CustomProfileDraft {
    struct Group: Identifiable, Codable {
        var id = UUID()
        var name: String
        var type: String
        var members: [String]
        var providers: [String]
        var testURL: String
    }

    struct Source {
        let name: String
        let yaml: String
    }

    struct Inventory {
        var proxies: [[String: Any]] = []
        var proxyProviders: [String: Any] = [:]
        var ruleProviders: [String: Any] = [:]
        var proxyNames: [String] { proxies.compactMap { $0["name"] as? String } }
    }

    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case .invalid(let detail): detail }
        }
    }

    struct ResolvedSources {
        var sources: [Source]
        var revisions: [UUID: UUID]
        var inventory: Inventory
    }

    static func resolveSources(
        recipe: CustomProfileRecipe, profiles: [Profile], excluding profileID: UUID? = nil,
        load: (Profile) throws -> String
    ) throws -> ResolvedSources {
        let ids = recipe.sourceProfileIDs
        guard Set(ids).count == ids.count, profileID.map({ !ids.contains($0) }) ?? true else {
            throw Failure.invalid("自定义配置的来源无效。")
        }
        let byID = Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var sources: [Source] = []
        var revisions: [UUID: UUID] = [:]
        for id in ids {
            guard let profile = byID[id], profile.resolvedEngine == .clash, let revision = profile.clashRevision else {
                throw Failure.invalid("部分来源配置已删除或不可用，请重新选择。")
            }
            sources.append(Source(name: profile.name, yaml: try load(profile)))
            revisions[id] = revision
        }
        let links = recipe.manualLinks.trimmingCharacters(in: .whitespacesAndNewlines)
        if !links.isEmpty {
            let imported = try ClashImport.parse(Data(links.utf8))
            guard let yaml = imported.clashYAML else { throw ClashImport.Failure.unreadable }
            sources.append(Source(name: "手动节点", yaml: yaml))
        }
        let inventory = try inventory(sources)
        guard !inventory.proxyNames.isEmpty || !inventory.proxyProviders.isEmpty else {
            throw Failure.invalid("请选择包含节点的配置或输入节点链接。")
        }
        return ResolvedSources(sources: sources, revisions: revisions, inventory: inventory)
    }

    static func inventory(_ sources: [Source]) throws -> Inventory {
        var result = Inventory()
        var names: Set<String> = []
        for source in sources {
            var error: NSError?
            guard let box = ClashYamlToJSON(source.yaml, &error),
                  let document = try? JSONSerialization.jsonObject(with: Data(box.value.utf8)) as? [String: Any] else {
                throw Failure.invalid("无法读取「\(source.name)」的节点。")
            }
            for proxy in document["proxies"] as? [[String: Any]] ?? [] {
                guard let name = proxy["name"] as? String, !name.isEmpty,
                      names.insert(name).inserted else {
                    throw Failure.invalid("「\(source.name)」包含重复或无名节点，请先重命名。")
                }
                result.proxies.append(proxy)
            }
            for (name, value) in document["proxy-providers"] as? [String: Any] ?? [:] {
                guard result.proxyProviders[name] == nil else {
                    throw Failure.invalid("节点 Provider「\(name)」重复，请先重命名。")
                }
                result.proxyProviders[name] = value
            }
            for (name, value) in document["rule-providers"] as? [String: Any] ?? [:] {
                guard result.ruleProviders[name] == nil else {
                    throw Failure.invalid("规则 Provider「\(name)」重复，请先重命名。")
                }
                result.ruleProviders[name] = value
            }
        }
        return result
    }

    static func build(inventory: Inventory, groups: [Group], rules: [String]) throws -> String {
        let proxyNames = Set(inventory.proxyNames)
        guard !proxyNames.isEmpty || !inventory.proxyProviders.isEmpty else {
            throw Failure.invalid("请至少添加一个节点或节点 Provider。")
        }
        let groupNames = groups.map(\.name)
        guard !groups.isEmpty, Set(groupNames).count == groupNames.count,
              groupNames.allSatisfy({ !$0.isEmpty && !["DIRECT", "REJECT", "GLOBAL"].contains($0)
                  && !$0.contains(",") && !$0.contains(where: \.isNewline) && !proxyNames.contains($0) }) else {
            throw Failure.invalid("请添加名称唯一且不与节点冲突的策略组。")
        }
        let available = proxyNames.union(groupNames).union(["DIRECT", "REJECT"])
        let providers = Set(inventory.proxyProviders.keys)
        let encodedGroups: [[String: Any]] = try groups.map { group in
            guard ["select", "url-test", "fallback", "load-balance"].contains(group.type),
                  !group.members.isEmpty || !group.providers.isEmpty,
                  group.members.allSatisfy({ available.contains($0) && $0 != group.name }),
                  group.providers.allSatisfy(providers.contains) else {
                throw Failure.invalid("策略组「\(group.name)」包含无效成员。")
            }
            var output: [String: Any] = ["name": group.name, "type": group.type]
            if !group.members.isEmpty { output["proxies"] = group.members }
            if !group.providers.isEmpty { output["use"] = group.providers }
            if group.type != "select" {
                guard let url = URL(string: group.testURL), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                    throw Failure.invalid("策略组「\(group.name)」的测速地址无效。")
                }
                output["url"] = group.testURL
                output["interval"] = 300
            }
            return output
        }
        // Clash groups may refer to one another, but a cycle cannot resolve to
        // an outbound and can make a generated profile unusable.
        let dependencies = Dictionary(uniqueKeysWithValues: groups.map { ($0.name, $0.members.filter { groupNames.contains($0) }) })
        var visiting: Set<String> = []
        var visited: Set<String> = []
        func visit(_ name: String) throws {
            if visited.contains(name) { return }
            guard visiting.insert(name).inserted else {
                throw Failure.invalid("策略组之间不能循环引用：\(name)。")
            }
            for dependency in dependencies[name] ?? [] { try visit(dependency) }
            visiting.remove(name)
            visited.insert(name)
        }
        for name in groupNames { try visit(name) }
        let policies = Set(groupNames + ["DIRECT", "REJECT"])
        for (index, rule) in rules.enumerated() {
            let components = rule.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard let type = components.first, let policy = components.last, policies.contains(policy),
                  (type == "MATCH" ? components.count == 2 : components.count == 3),
                  type != "MATCH" || index == rules.count - 1,
                  type != "RULE-SET" || inventory.ruleProviders[components[1]] != nil else {
                throw Failure.invalid("规则「\(rule)」引用了无效策略或规则 Provider。")
            }
        }
        var effectiveRules = rules
        if !rules.contains(where: { $0.hasPrefix("MATCH,") }) {
            effectiveRules.append("MATCH,\(groupNames[0])")
        }
        var document: [String: Any] = [
            "mode": "rule", "proxies": inventory.proxies, "proxy-groups": encodedGroups,
            "rules": effectiveRules
        ]
        if !inventory.proxyProviders.isEmpty { document["proxy-providers"] = inventory.proxyProviders }
        if !inventory.ruleProviders.isEmpty { document["rule-providers"] = inventory.ruleProviders }
        let data = try JSONSerialization.data(withJSONObject: document, options: .sortedKeys)
        var error: NSError?
        guard let yaml = ClashJSONToYaml(String(decoding: data, as: UTF8.self), &error) else {
            throw error ?? Failure.invalid("无法生成配置。")
        }
        var validationError: NSError?
        guard ClashValidateConfigShape(yaml.value, &validationError) else {
            throw validationError ?? Failure.invalid("生成的配置格式无效。")
        }
        return yaml.value
    }
}
