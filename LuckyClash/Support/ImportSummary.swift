import Foundation

/// Human-readable subscription and byte values shared by the import preview,
/// profile and connection views.
enum ImportSummary {
    static func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .binary)
    }

    static func flow(_ subscription: Profile.Subscription) -> String {
        let down = bytes(subscription.download ?? 0)
        let up = bytes(subscription.upload ?? 0)
        guard let total = subscription.total, total > 0 else {
            return "↓ \(down) · ↑ \(up)"
        }
        let used = (subscription.download ?? 0) + (subscription.upload ?? 0)
        return "↓ \(down) · ↑ \(up) · \(bytes(used)) / \(bytes(total))"
    }

    static func expiry(_ date: Date?) -> String {
        guard let date else { return "长期" }
        return date < Date()
            ? "已到期"
            : date.formatted(date: .abbreviated, time: .omitted)
    }
}
