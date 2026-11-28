import Clash
import Foundation

nonisolated enum ClashOverridePipeline {
    static func compose(
        _ yaml: String, global: ConfigurationOverrides, profile: ConfigurationOverrides
    ) throws -> String {
        guard global != .empty || profile != .empty else { return yaml }
        var text = yaml
        for patch in [global.patch, profile.patch] where !patch.isEmpty {
            let options = try encode(["patch": patch])
            var error: NSError?
            guard let result = ClashMergeOverrideForIOS(text, options, &error) else {
                throw error ?? ClashImport.Failure.unreadable
            }
            text = result.value
        }

        let before = global.prependRules + profile.prependRules
        let after = global.appendRules + profile.appendRules
        guard !before.isEmpty || !after.isEmpty else { return text }

        // Keep rule comments and ordering when the source uses a block list.
        var error: NSError?
        if let catalog = ClashOpenRuleCatalogForIOS(text, &error) {
            let total = Int(catalog.total())
            catalog.close()
            let ops = before.enumerated().map { ["op": "insert", "index": $0.offset, "rule": $0.element] }
                + after.enumerated().map {
                    ["op": "insert", "index": total + before.count + $0.offset, "rule": $0.element]
                }
            if let edited = ClashEditRulesForIOS(text, try encode(ops), nil) { return edited.text }
        }
        // The catalog editor needs block-style rules. The merge API handles
        // imported flow sequences and documents without a rules key.
        for (rules, prepend) in [(before, true), (after, false)] where !rules.isEmpty {
            let options = try encode(["appendRules": rules, "prependRules": prepend])
            var error: NSError?
            guard let result = ClashMergeOverrideForIOS(text, options, &error) else {
                throw error ?? ClashImport.Failure.unreadable
            }
            text = result.value
        }
        return text
    }

    private static func encode(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
}
