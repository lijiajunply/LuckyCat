import Foundation
import Testing
@testable import LuckyClash

struct CustomProfileDraftTests {
    @Test func resolvesCurrentSourceAndDetectsStaleOrMissingRevisions() throws {
        let id = UUID(), oldRevision = UUID(), newRevision = UUID()
        let source = Profile(id: id, name: "Source", nodes: [], selectedNodeID: UUID(),
                             engine: .clash, clashRevision: newRevision)
        let group = CustomProfileDraft.Group(name: "Proxy", type: "select", members: ["New"],
                                             providers: [], testURL: "")
        var recipe = CustomProfileRecipe(sourceProfileIDs: [id], manualLinks: "", groups: [group], rules: [],
                                         sourceRevisions: [id: oldRevision])
        #expect(recipe.sourcesChanged(in: [source]))
        let resolved = try CustomProfileDraft.resolveSources(recipe: recipe, profiles: [source]) { _ in
            "proxies:\n  - {name: New, type: socks5, server: example.com, port: 1080}\n"
        }
        #expect(resolved.inventory.proxyNames == ["New"])
        recipe.sourceRevisions = resolved.revisions
        #expect(!recipe.sourcesChanged(in: [source]))
        #expect(recipe.sourcesChanged(in: []))
        #expect(throws: (any Error).self) {
            try CustomProfileDraft.resolveSources(recipe: recipe, profiles: [], load: { _ in "" })
        }
        #expect(throws: (any Error).self) {
            try CustomProfileDraft.resolveSources(recipe: recipe, profiles: [source], excluding: id, load: { _ in "" })
        }
        let restoredRevision = UUID()
        recipe.remapSourceRevisions(original: [id: newRevision], restored: [id: restoredRevision])
        #expect(recipe.sourceRevisions?[id] == restoredRevision)
        recipe.sourceRevisions = [id: oldRevision]
        recipe.remapSourceRevisions(original: [id: newRevision], restored: [id: restoredRevision])
        #expect(recipe.sourceRevisions?[id] == oldRevision)
    }

    @Test func recipeSurvivesProfileEncodingAndOldProfilesStillDecode() throws {
        let group = CustomProfileDraft.Group(name: "Proxy", type: "select", members: ["Node"],
                                             providers: [], testURL: "")
        let source = UUID()
        var profile = Profile(id: UUID(), name: "Custom", nodes: [], selectedNodeID: UUID())
        profile.customRecipe = CustomProfileRecipe(sourceProfileIDs: [source], manualLinks: "ss://example",
                                                  groups: [group], rules: ["MATCH,Proxy"])
        let encoded = try JSONEncoder().encode(profile)
        let restored = try JSONDecoder().decode(Profile.self, from: encoded)
        #expect(restored.customRecipe?.sourceProfileIDs == [source])
        #expect(restored.customRecipe?.manualLinks == "ss://example")
        #expect(restored.customRecipe?.groups.first?.id == group.id)
        #expect(restored.customRecipe?.groups.first?.members == ["Node"])
        #expect(restored.customRecipe?.rules == ["MATCH,Proxy"])

        var old = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        old.removeValue(forKey: "customRecipe")
        let legacy = try JSONSerialization.data(withJSONObject: old)
        #expect(try JSONDecoder().decode(Profile.self, from: legacy).customRecipe == nil)
    }

    @Test func buildsGroupsAndAddsFallbackRule() throws {
        let source = CustomProfileDraft.Source(name: "source", yaml: """
        proxies:
          - {name: Node, type: socks5, server: example.com, port: 1080}
        """)
        let inventory = try CustomProfileDraft.inventory([source])
        let group = CustomProfileDraft.Group(name: "Proxy", type: "select", members: ["Node"],
                                             providers: [], testURL: "")
        let yaml = try CustomProfileDraft.build(inventory: inventory, groups: [group],
                                               rules: ["DOMAIN-SUFFIX,example.com,DIRECT"])
        #expect(yaml.contains("MATCH,Proxy"))
        let imported = try ClashImport.parse(Data(yaml.utf8))
        #expect(imported.nodes.map(\.name) == ["Node"])
        #expect(imported.groups.first?.name == "Proxy")
    }

    @Test func rejectsDuplicateNodesAndMissingRuleTarget() throws {
        let source = CustomProfileDraft.Source(name: "source", yaml: """
        proxies:
          - {name: Node, type: socks5, server: example.com, port: 1080}
        """)
        #expect(throws: (any Error).self) { try CustomProfileDraft.inventory([source, source]) }
        let inventory = try CustomProfileDraft.inventory([source])
        let group = CustomProfileDraft.Group(name: "Proxy", type: "select", members: ["Node"],
                                             providers: [], testURL: "")
        #expect(throws: (any Error).self) {
            try CustomProfileDraft.build(inventory: inventory, groups: [group], rules: ["MATCH,Deleted"])
        }
    }

    @Test func rejectsCyclesAndRulesAfterMatch() throws {
        let source = CustomProfileDraft.Source(name: "source", yaml: """
        proxies:
          - {name: Node, type: socks5, server: example.com, port: 1080}
        """)
        let inventory = try CustomProfileDraft.inventory([source])
        let first = CustomProfileDraft.Group(name: "First", type: "select", members: ["Second"],
                                             providers: [], testURL: "")
        let second = CustomProfileDraft.Group(name: "Second", type: "select", members: ["First", "Node"],
                                              providers: [], testURL: "")
        #expect(throws: (any Error).self) {
            try CustomProfileDraft.build(inventory: inventory, groups: [first, second], rules: [])
        }
        let valid = CustomProfileDraft.Group(name: "Proxy", type: "select", members: ["Node"],
                                             providers: [], testURL: "")
        #expect(throws: (any Error).self) {
            try CustomProfileDraft.build(inventory: inventory, groups: [valid],
                                         rules: ["MATCH,Proxy", "DOMAIN,example.com,DIRECT"])
        }
        #expect(throws: (any Error).self) {
            try CustomProfileDraft.build(inventory: inventory, groups: [valid],
                                         rules: ["MATCH,Proxy", "MATCH,DIRECT"])
        }
    }
}
