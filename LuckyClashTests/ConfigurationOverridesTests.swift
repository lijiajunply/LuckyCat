import Foundation
import Testing
@testable import LuckyClash

struct ConfigurationOverridesTests {
    @Test func logLevelAndRulesMergeWithoutChangingOriginal() throws {
        let source = """
        mode: rule
        log-level: warning
        rules:
          - MATCH,DIRECT
        """
        var global = ConfigurationOverrides.empty
        global.logLevel = "debug"
        global.prependRules = ["DOMAIN,example.com,DIRECT"]
        let result = try ClashOverridePipeline.compose(source, global: global, profile: .empty)
        #expect(source.contains("log-level: warning"))
        #expect(result.contains("log-level: debug"))
        let domain = try #require(result.range(of: "DOMAIN,example.com,DIRECT"))
        let match = try #require(result.range(of: "MATCH,DIRECT"))
        #expect(domain.lowerBound < match.lowerBound)
    }

    @Test func legacyOverridesDecodeWithoutLogLevel() throws {
        let data = Data(#"{"prependRules":[],"appendRules":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(ConfigurationOverrides.self, from: data)
        #expect(decoded.logLevel == nil)
        #expect(decoded == .empty)
    }
}
