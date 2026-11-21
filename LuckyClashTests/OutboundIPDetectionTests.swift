import Foundation
import Testing
@testable import LuckyClash

struct OutboundIPParsingTests {
    @Test func parsesIpQueryResidentialReport() throws {
        let report = try OutboundIPSources.parseIpQuery(Data("""
        {"ip":"49.64.52.232","isp":{"asn":"AS140292","org":"CHINANET Jiangsu",\
        "isp":"CHINANET"},"location":{"country":"China","country_code":"CN"},\
        "risk":{"is_mobile":false,"is_vpn":false,"is_tor":false,"is_proxy":false,\
        "is_datacenter":false,"risk_score":0}}
        """.utf8))

        #expect(report.ip == "49.64.52.232")
        #expect(report.countryCode == "CN")
        #expect(report.kind == .residential)
        #expect(report.quality == .good)
        #expect(report.organization == "CHINANET Jiangsu")
        #expect(report.asn == 140_292)
        #expect(report.flags.isEmpty)
        #expect(report.source == "ipquery.io")
    }

    @Test func parsesIpQueryHostingAndFlags() throws {
        let report = try OutboundIPSources.parseIpQuery(Data("""
        {"ip":"8.8.8.8","isp":{"asn":"AS15169","org":"Google LLC"},\
        "location":{"country":"United States","country_code":"US"},\
        "risk":{"is_datacenter":true,"is_proxy":true,"is_vpn":true,\
        "is_tor":false,"is_abuser":false}}
        """.utf8))

        #expect(report.kind == .hosting)
        #expect(report.quality == .normal)
        #expect(report.flags == ["VPN", "代理"])
        #expect(report.countryCode == "US")
    }

    @Test func parsesIpQueryTorAsRisky() throws {
        let report = try OutboundIPSources.parseIpQuery(Data("""
        {"ip":"203.0.113.9","location":{"country":"Singapore","country_code":"SG"},\
        "risk":{"is_mobile":true,"is_tor":true}}
        """.utf8))

        #expect(report.kind == .mobile)
        #expect(report.quality == .risky)
        #expect(report.flags == ["Tor"])
    }

    @Test func parsesIdentMeDeclaredType() throws {
        let report = try OutboundIPSources.parseIdentMe(Data("""
        {"ip":"240e:3a7:4c2a:74b0:f43a:a1f2:f52:ef46","aso":"Chinanet",\
        "asn":4134,"type":"residential","cc":"CN","country":"China"}
        """.utf8))

        #expect(report.ip == "240e:3a7:4c2a:74b0:f43a:a1f2:f52:ef46")
        #expect(report.kind == .residential)
        #expect(report.quality == .good)
        #expect(report.organization == "Chinanet")
        #expect(report.asn == 4_134)
        #expect(report.source == "ident.me")
    }

    @Test func parsesIpWhoIsSecurityFlags() throws {
        let report = try OutboundIPSources.parseIpWhoIs(Data("""
        {"ip":"8.8.8.8","success":true,"country":"United States",\
        "country_code":"US","connection":{"asn":15169,"org":"Google LLC",\
        "isp":"Google LLC"},"security":{"hosting":true,"proxy":true,\
        "vpn":false,"tor":false,"abuser":false}}
        """.utf8))

        #expect(report.kind == .hosting)
        #expect(report.quality == .normal)
        #expect(report.flags == ["代理"])
        #expect(report.organization == "Google LLC")
        #expect(report.asn == 15_169)
    }

    @Test func parsesIpApiIsFallback() throws {
        let report = try OutboundIPSources.parseIpApiIs(Data("""
        {"ip":"8.8.8.8","company":"Google LLC",\
        "asn":"AS15169 Google LLC","country":"United States"}
        """.utf8))

        #expect(report.kind == .unknown)
        #expect(report.quality == .normal)
        #expect(report.organization == "Google LLC")
        #expect(report.asn == 15_169)
        #expect(report.countryCode == nil)
    }

    @Test func rejectsInvalidPayloads() {
        #expect(throws: (any Error).self) {
            try OutboundIPSources.parseIpQuery(Data("not json".utf8))
        }
        #expect(throws: (any Error).self) {
            try OutboundIPSources.parseIpQuery(Data(#"{"ip":"not-an-ip"}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            try OutboundIPSources.parseIpWhoIs(Data(#"{"success":false}"#.utf8))
        }
    }
}

@MainActor
@Suite(.serialized)
struct OutboundIPDetectionTests {
    private let report = OutboundIPReport(
        ip: "203.0.113.42",
        countryCode: "SG",
        country: "Singapore",
        kind: .hosting,
        organization: "Example Cloud Ltd.",
        asn: 64_500,
        source: "ipquery.io",
        checkedAt: .now
    )

    @Test func refreshStoresReport() async {
        let report = self.report
        let detection = OutboundIPDetection(lookup: OutboundIPLookup { report })
        await detection.refresh().value

        #expect(!detection.isChecking)
        #expect(detection.report?.ip == report.ip)
        #expect(detection.lastAttemptAt != nil)
        #expect(detection.failure == nil)
    }

    @Test func refreshIfStaleSkipsRecentAttempt() async {
        let report = self.report
        let counter = Counter()
        let detection = OutboundIPDetection(lookup: OutboundIPLookup {
            await counter.increment()
            return report
        })

        await detection.refreshIfStale()?.value
        let second = detection.refreshIfStale()
        let count = await counter.value

        #expect(second == nil)
        #expect(count == 1)
        #expect(detection.report != nil)
    }

    @Test func failureKeepsTheLastReport() async throws {
        let report = self.report
        let stub = LookupStub([
            .success(report),
            .failure(OutboundIPFailure(failures: [
                .init(source: "ipquery.io", reason: "请求超时"),
            ])),
        ])
        let detection = OutboundIPDetection(lookup: OutboundIPLookup {
            try await stub.next()
        })

        await detection.refresh().value
        await detection.refresh().value

        #expect(detection.report?.ip == report.ip)
        #expect(detection.failure?.failures.first?.source == "ipquery.io")
        #expect(!detection.isChecking)
    }

    @Test func failureWithoutReportIsExposed() async {
        let detection = OutboundIPDetection(lookup: OutboundIPLookup {
            throw OutboundIPFailure(failures: [
                .init(source: "ident.me", reason: "无法连接"),
            ])
        })
        await detection.refresh().value

        #expect(detection.report == nil)
        #expect(detection.failure?.failures.first?.reason == "无法连接")
        #expect(detection.lastAttemptAt != nil)
    }
}

private actor Counter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private actor LookupStub {
    private var results: [Result<OutboundIPReport, OutboundIPFailure>]

    init(_ results: [Result<OutboundIPReport, OutboundIPFailure>]) {
        self.results = results
    }

    func next() throws -> OutboundIPReport {
        guard !results.isEmpty else { throw CancellationError() }
        return try results.removeFirst().get()
    }
}
