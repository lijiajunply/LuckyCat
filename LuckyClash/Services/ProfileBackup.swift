import CoreFoundation
import Foundation

struct ProfileBackup: Codable {
    struct ProfileData: Codable {
        struct LegacyNode: Codable {
            let configuration: PrototypeConfiguration
            let routePlan: RoutePlan?
        }
        let profile: Profile
        let yaml: String?
        let legacyNodes: [UUID: LegacyNode]?
    }

    let version: Int
    let profiles: [ProfileData]
    let selectedProfileID: UUID?
    let mode: TrafficMode?
    let overrides: ConfigurationOverrides?
    let preferences: [String: Data]

    static let preferenceKeys = [
        "appLanguage", "hideOutboundIP", "strategyGroupTabs", "nodeGridLayout", "hideTimedOutNodes", "nodeSortOrder",
        "closeConnectionsOnNodeSwitch", "latencyTestURL", ClashDelayRequest.timeoutKey,
        ClashGeodata.geoIPSourceKey, ClashGeodata.geoSiteSourceKey, ClashGeodata.updateIntervalKey,
        RemoteImport.userAgentModeKey, RemoteImport.customUserAgentKey, RemoteImport.verifyCertificateKey,
        TunnelNetworkOptions.ipv6Mode, TunnelNetworkOptions.queryMode, TunnelNetworkOptions.mtu,
        TunnelNetworkOptions.includeAllNetworks, TunnelNetworkOptions.bypassPrivate,
        TunnelNetworkOptions.statisticsProxyOnly, TunnelNetworkOptions.onDemand,
        TunnelNetworkOptions.excludedSSIDs, AppAppearance.modeKey, AppAppearance.accentKey
    ]

    static func capture(_ library: ProfileLibrary) throws -> ProfileBackup {
        let entries = try library.profiles.map { profile -> ProfileData in
            if profile.resolvedEngine == .clash {
                let revision = profile.clashRevision ?? profile.selectedNodeID
                return ProfileData(profile: profile,
                                   yaml: try ClashTunnelStore.load(profileID: profile.id, revision: revision),
                                   legacyNodes: nil)
            }
            var nodes: [UUID: ProfileData.LegacyNode] = [:]
            for node in profile.nodes {
                let snapshot = try TunnelSnapshot.loadTunnel(profileID: profile.id, revision: node.id)
                nodes[node.id] = .init(configuration: snapshot.configuration, routePlan: snapshot.routePlan)
            }
            return ProfileData(profile: profile, yaml: nil, legacyNodes: nodes)
        }
        var preferences: [String: Data] = [:]
        for key in preferenceKeys {
            if let value = UserDefaults.standard.object(forKey: key) {
                preferences[key] = try PropertyListSerialization.data(
                    fromPropertyList: ["value": value], format: .binary, options: 0
                )
            }
        }
        return ProfileBackup(version: 1, profiles: entries, selectedProfileID: library.selectedProfileID,
                             mode: library.mode, overrides: library.overrides, preferences: preferences)
    }

    func decodedPreferences() throws -> [String: Any] {
        guard preferences.keys.allSatisfy({ Self.preferenceKeys.contains($0) }) else {
            throw BackupEncryption.Failure.invalidBackup
        }
        var values: [String: Any] = [:]
        for (key, data) in preferences {
            guard data.count <= 16_384,
                  let container = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let value = container["value"] else {
                throw BackupEncryption.Failure.invalidBackup
            }
            let boolKeys: Set<String> = [
                "hideOutboundIP", "strategyGroupTabs", "nodeGridLayout", "hideTimedOutNodes",
                "closeConnectionsOnNodeSwitch", RemoteImport.verifyCertificateKey,
                TunnelNetworkOptions.includeAllNetworks, TunnelNetworkOptions.bypassPrivate,
                TunnelNetworkOptions.statisticsProxyOnly, TunnelNetworkOptions.onDemand
            ]
            let integerKeys: Set<String> = [
                ClashDelayRequest.timeoutKey, ClashGeodata.updateIntervalKey, TunnelNetworkOptions.mtu
            ]
            if boolKeys.contains(key) {
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    throw BackupEncryption.Failure.invalidBackup
                }
            } else if integerKeys.contains(key) {
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
                    throw BackupEncryption.Failure.invalidBackup
                }
            } else {
                guard value is String else { throw BackupEncryption.Failure.invalidBackup }
            }
            values[key] = value
        }
        return values
    }
}
