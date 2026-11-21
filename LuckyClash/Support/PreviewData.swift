#if DEBUG
import Foundation

/// Sample state shared by the SwiftUI previews. Nothing here is used by the
/// shipping app, and nothing touches the on-disk library or the keychain.
enum PreviewSamples {
    // MARK: - Stable identifiers

    static let profileID = UUID(uuidString: "A11CE000-0000-0000-0000-000000000001")!
    static let localProfileID = UUID(uuidString: "A11CE000-0000-0000-0000-000000000002")!
    static let revision = UUID(uuidString: "A11CE000-0000-0000-0000-000000000003")!
    static let subscriptionURL = URL(
        string: "https://sub.example.com/api/v1/client/subscribe?token=preview"
    )!

    // MARK: - Nodes

    static let hongKong = Profile.Node(
        id: UUID(uuidString: "A11CE000-0000-0000-0000-000000000101")!,
        name: "香港 01 · IEPL",
        endpoint: "hk01.example.com:443",
        type: "vmess"
    )

    static let japan = Profile.Node(
        id: UUID(uuidString: "A11CE000-0000-0000-0000-000000000102")!,
        name: "日本 02 · 专线",
        endpoint: "jp02.example.com:8443",
        type: "trojan"
    )

    static let singapore = Profile.Node(
        id: UUID(uuidString: "A11CE000-0000-0000-0000-000000000103")!,
        name: "新加坡 03",
        endpoint: "sg03.example.com:443",
        type: "vless"
    )

    static let losAngeles = Profile.Node(
        id: UUID(uuidString: "A11CE000-0000-0000-0000-000000000104")!,
        name: "美国 04 · 家宽",
        endpoint: "us04.example.com:443",
        type: "hysteria2"
    )

    static let nodes: [Profile.Node] = [hongKong, japan, singapore, losAngeles]

    // MARK: - Groups

    static let groups: [ClashImportGroup] = [
        ClashImportGroup(
            name: "LuckyClash",
            type: "select",
            members: ["自动选择", hongKong.name, japan.name, singapore.name, losAngeles.name]
        ),
        ClashImportGroup(
            name: "自动选择",
            type: "url-test",
            members: [hongKong.name, japan.name, singapore.name, losAngeles.name],
            testURL: "https://www.apple.com/library/test/success.html"
        ),
        ClashImportGroup(
            name: "流媒体",
            type: "select",
            members: [hongKong.name, japan.name]
        ),
    ]

    // MARK: - Subscription

    static func subscription(
        download: UInt64 = 86_469_492_736,
        upload: UInt64 = 12_884_901_888,
        total: UInt64 = 322_122_547_200,
        expiresInDays: Int = 42,
        lastUpdated: Date = .now
    ) -> Profile.Subscription {
        var subscription = Profile.Subscription()
        subscription.upload = upload
        subscription.download = download
        subscription.total = total
        subscription.expire = Calendar.current.date(byAdding: .day, value: expiresInDays, to: .now)
        subscription.updateIntervalHours = 24
        subscription.webPageURL = "https://example.com/user"
        subscription.lastUpdated = lastUpdated
        return subscription
    }

    // MARK: - Profiles

    static var subscriptionProfile: Profile {
        Profile(
            id: profileID,
            name: "机场订阅",
            nodes: nodes,
            selectedNodeID: hongKong.id,
            sourceURL: subscriptionURL,
            rules: nil,
            engine: .clash,
            clashRevision: revision,
            clashGroup: "LuckyClash",
            clashGroups: groups,
            subscription: subscription(),
            autoUpdate: true
        )
    }

    static var expiringSubscriptionProfile: Profile {
        var profile = subscriptionProfile
        profile.subscription = subscription(
            download: 300_647_219_200,
            upload: 21_474_836_480,
            total: 322_122_547_200,
            expiresInDays: 3
        )
        return profile
    }

    static var localProfile: Profile {
        Profile(
            id: localProfileID,
            name: "本地测试节点",
            nodes: nodes,
            selectedNodeID: japan.id,
            sourceURL: nil,
            rules: nil,
            engine: .clash,
            clashRevision: revision,
            clashGroup: nil,
            clashGroups: [],
            subscription: nil,
            autoUpdate: false
        )
    }

    // MARK: - Library

    static func library(
        profiles: [Profile]? = nil,
        selectedProfileID: UUID? = nil,
        mode: TrafficMode = .rule
    ) -> ProfileLibrary {
        var library = ProfileLibrary()
        library.profiles = profiles ?? [subscriptionProfile]
        library.selectedProfileID = selectedProfileID ?? library.profiles.first?.id
        library.mode = mode
        return library
    }

    // MARK: - Latency

    static func latencyResults(forProfile profileID: UUID) -> [UUID: [String: Int]] {
        [profileID: [
            hongKong.name: 38,
            japan.name: 74,
            singapore.name: 128,
            losAngeles.name: 189,
        ]]
    }

    // MARK: - Staged import

    static var importedNodes: [ImportedNode] {
        nodes.map { ImportedNode(name: $0.name, type: $0.type ?? "clash", endpoint: $0.endpoint) }
    }

    static var importedRules: [RoutingRule] {
        [
            RoutingRule(kind: .ipv4, value: "10.0.0.0/8", policy: .direct),
            RoutingRule(kind: .ipv6, value: "2001:db8::/32", policy: .direct),
            RoutingRule(kind: .match, value: nil, policy: .proxy),
        ]
    }

    static let importWarnings = [
        "3 条 DOMAIN 规则由 Clash 内核执行，不参与系统路由生成。",
        "1 条 REJECT 规则已跳过。",
    ]

    // MARK: - Network

    static var connections: [ClashConnection] {
        [
            connection(
                id: "A11CE000-0000-0000-0000-000000000201",
                host: "www.youtube.com", address: "142.250.72.14", port: "443",
                rule: "DomainSuffix", rulePayload: "youtube.com",
                chains: ["LuckyClash", hongKong.name], download: 4_312_960, upload: 88_320,
                network: "tcp", type: "HTTPS"
            ),
            connection(
                id: "A11CE000-0000-0000-0000-000000000202",
                host: "github.com", address: "140.82.112.3", port: "443",
                rule: "DomainSuffix", rulePayload: "github.com",
                chains: ["LuckyClash", japan.name], download: 912_384, upload: 41_472,
                network: "tcp", type: "HTTPS"
            ),
            connection(
                id: "A11CE000-0000-0000-0000-000000000203",
                host: "", address: "119.29.29.29", port: "53",
                rule: "MATCH", rulePayload: "",
                chains: ["DIRECT"], download: 2_048, upload: 1_024,
                network: "udp", type: "DNS"
            ),
        ]
    }

    private static func connection(
        id: String,
        host: String,
        address: String,
        port: String,
        rule: String,
        rulePayload: String,
        chains: [String],
        download: UInt64,
        upload: UInt64,
        network: String,
        type: String
    ) -> ClashConnection {
        var connection = ClashConnection(id: id)
        connection.metadata.host = host
        connection.metadata.destinationIP = address
        connection.metadata.destinationPort = port
        connection.metadata.sourceIP = "192.168.1.12"
        connection.metadata.sourcePort = "51234"
        connection.metadata.network = network
        connection.metadata.type = type
        connection.metadata.dnsMode = "fake-ip"
        connection.metadata.destinationGeoIP = ["US"]
        connection.rule = rule
        connection.rulePayload = rulePayload
        connection.chains = chains
        connection.download = download
        connection.upload = upload
        connection.start = Date().addingTimeInterval(-42)
        return connection
    }

    static var logs: [ClashLogEntry] {
        [
            log("info", "[TCP] 192.168.1.12:51234 --> www.youtube.com:443 match DomainSuffix(youtube.com) using \(hongKong.name)"),
            log("info", "[UDP] 192.168.1.12:53211 --> 119.29.29.29:53 match Match() using DIRECT"),
            log("warning", "timeout when dialing \(losAngeles.name): context deadline exceeded"),
            log("info", "[TCP] 192.168.1.12:51566 --> github.com:443 match DomainSuffix(github.com) using \(japan.name)"),
            log("error", "proxy \(losAngeles.name): connection reset by peer"),
        ]
    }

    private static func log(_ level: String, _ payload: String) -> ClashLogEntry {
        ClashLogEntry(
            id: UUID(),
            date: Date().addingTimeInterval(-Double.random(in: 1...30)),
            level: ClashLogEntry.Level(label: level),
            payload: payload,
            tag: payload.hasPrefix("[")
                ? String(payload.dropFirst().prefix { $0 != "]" })
                : nil
        )
    }

    // MARK: - Outbound IP

    static let outboundIP = OutboundIPReport(
        ip: "203.0.113.42",
        countryCode: "SG",
        country: "Singapore",
        kind: .hosting,
        organization: "Example Cloud Ltd.",
        asn: 64_500,
        isProxy: true,
        isVPN: true,
        source: "ipquery.io",
        checkedAt: .now
    )

    // MARK: - Diagnostics

    static func diagnosticLog() -> DiagnosticLog {
        let log = DiagnosticLog(fileURL: nil)
        log.append("配置已保存")
        log.append("发起连接")
        log.append("系统 VPN 状态 3")
        log.append("扩展已就绪")
        return log
    }
}
#endif
