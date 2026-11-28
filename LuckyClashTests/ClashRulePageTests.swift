import Testing
@testable import LuckyClash

struct ClashRulePageTests {
    @Test func mergesStatisticsForMatchingCatalogRulesOnly() throws {
        let catalog = try ClashRulePage.decode("""
        {"total":2,"matched":2,"rules":[
          {"index":0,"type":"DOMAIN-SUFFIX","rule":"DOMAIN-SUFFIX,example.com,Proxy","target":"Proxy"},
          {"index":1,"type":"IP-CIDR","rule":"IP-CIDR,1.1.1.0/24,DIRECT","target":"DIRECT"}
        ]}
        """)
        let live = try ClashRulePage.decode("""
        {"total":2,"rules":[
          {"index":0,"type":"DomainSuffix","payload":"example.com","proxy":"Proxy","extra":{"hitCount":12}},
          {"index":1,"type":"IPCIDR","payload":"8.8.8.0/24","proxy":"DIRECT","extra":{"hitCount":99}}
        ]}
        """)
        let merged = catalog.addingStatistics(Dictionary(uniqueKeysWithValues: live.rules.map { ($0.index, $0) }))
        #expect(merged.rules[0].extra?.hitCount == 12)
        #expect(merged.rules[1].extra == nil)
        #expect(merged.matched == 2)
    }
}
