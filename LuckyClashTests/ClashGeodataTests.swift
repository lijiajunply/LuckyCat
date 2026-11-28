import Foundation
import Testing
@testable import LuckyClash

struct ClashGeodataTests {
    private enum TestFailure: Error { case download }

    @Test func detectsGeodataUsingCoreResourcePlan() {
        let dnsOnly = """
        dns:
          enable: true
          nameserver-policy:
            'geosite:cn': [223.5.5.5]
        rules:
          - MATCH,DIRECT
        """
        #expect(ClashGeodata.requirements(for: dnsOnly).map(\.kind) == ["geosite"])
        let ipDat = "geodata-mode: true\nrules:\n  - GEOIP,CN,DIRECT\n  - MATCH,DIRECT"
        let ipDatabase = "geodata-mode: false\nrules:\n  - GEOIP,CN,DIRECT\n  - MATCH,DIRECT"
        #expect(ClashGeodata.requirements(for: ipDat).first?.format == "dat")
        #expect(ClashGeodata.requirements(for: ipDatabase).first?.format == "mmdb")
        #expect(!ClashGeodata.isRequired("# GEOIP,CN,DIRECT\nrules:\n  - MATCH,DIRECT"))
    }

    @Test func automaticUpdateKeepsUsableResourceButExplicitUpdateReportsFailure() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let old = Data(repeating: 0x42, count: 100 * 1024)
        try old.write(to: file)
        try await ClashGeodata.install(destination: file, canUseExistingOnFailure: true) {
            throw TestFailure.download
        }
        #expect(try Data(contentsOf: file) == old)
        do {
            try await ClashGeodata.install(destination: file, canUseExistingOnFailure: false) {
                throw TestFailure.download
            }
            Issue.record("An explicit update must report download failure")
        } catch TestFailure.download { }
        #expect(try Data(contentsOf: file) == old)
        try FileManager.default.removeItem(at: file)
        do {
            try await ClashGeodata.install(destination: file, canUseExistingOnFailure: true) {
                throw TestFailure.download
            }
            Issue.record("A missing resource cannot satisfy the update")
        } catch TestFailure.download { }
    }
}
