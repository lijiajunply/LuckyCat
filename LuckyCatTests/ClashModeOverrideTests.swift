import Testing
@testable import LuckyCat

struct ClashModeOverrideTests {
    @Test func replacesTopLevelMode() {
        let yaml = """
        mode: rule
        proxies: []
        rules:
          - MATCH,DIRECT
        """
        let output = ClashModeOverride.apply(.global, to: yaml)
        #expect(output.hasPrefix("mode: global\n"))
        #expect(!output.contains("mode: rule"))
        #expect(output.contains("rules:"))
    }

    @Test func insertsModeWhenMissing() {
        let yaml = "proxies: []\nrules: []\n"
        let output = ClashModeOverride.apply(.direct, to: yaml)
        #expect(output == "mode: direct\nproxies: []\nrules: []\n")
    }

    @Test func ignoresNestedAndCommentedKeys() {
        let yaml = """
        # mode: rule
        proxies:
          - name: only
            mode: rule
        rules: []
        """
        let output = ClashModeOverride.apply(.global, to: yaml)
        #expect(output.hasPrefix("mode: global\n"))
        #expect(output.contains("# mode: rule"))
        #expect(output.contains("    mode: rule"))
    }

    @Test func preservesWindowsLineEndings() {
        let output = ClashModeOverride.apply(.direct, to: "mode: rule\r\nrules: []\r\n")
        #expect(output == "mode: direct\r\nrules: []\r\n")
    }

    @Test func acceptsSpacedColon() {
        let output = ClashModeOverride.apply(.global, to: "mode : rule\nrules: []\n")
        #expect(output == "mode: global\nrules: []\n")
    }
}
