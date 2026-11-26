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

    func publish() {
        guard let url = Self.snapshotURL, Self.snapshot()?.status != self else { return }
        let snapshot = Snapshot(status: self, updatedAt: .now)
        do {
            try JSONEncoder().encode(snapshot).write(
                to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            WidgetCenter.shared.reloadTimelines(ofKind: Self.kind)
        } catch {
            // The shared snapshot is optional and must not interrupt VPN operations.
        }
    }
}
