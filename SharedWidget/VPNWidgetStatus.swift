import Foundation
import WidgetKit

enum VPNWidgetStatus: String, Codable {
    case disconnected
    case connecting
    case connected
    case disconnecting
    case unknown

    struct Snapshot: Codable {
        let status: VPNWidgetStatus
        let updatedAt: Date
        let group: String?
        let node: String?
    }

    static let kind = "LuckyClashVPNStatus"
    static let connectionURL = URL(string: "luckyclash://connection")!

    private static var snapshotURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.luckyfish.LuckyClash"
        )?.appending(path: "VPNWidgetStatus.json")
    }

    static func snapshot() -> Snapshot? {
        guard let snapshotURL, let data = try? Data(contentsOf: snapshotURL) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    func publish(group: String? = nil, node: String? = nil) {
        guard let url = Self.snapshotURL else { return }
        let previous = Self.snapshot()
        let currentGroup = self == .connected ? (group ?? previous?.group) : nil
        let currentNode = self == .connected ? (node ?? previous?.node) : nil
        guard previous?.status != self || previous?.group != currentGroup || previous?.node != currentNode else { return }
        let snapshot = Snapshot(status: self, updatedAt: .now, group: currentGroup, node: currentNode)
        do {
            try JSONEncoder().encode(snapshot).write(
                to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            WidgetCenter.shared.reloadTimelines(ofKind: Self.kind)
            if #available(iOS 18.0, *) {
                ControlCenter.shared.reloadControls(ofKind: "LuckyClashVPNControl")
            }
        } catch {
            // The shared snapshot is optional and must not interrupt VPN operations.
        }
    }
}
