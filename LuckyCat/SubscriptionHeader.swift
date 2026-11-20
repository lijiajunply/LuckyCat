import Foundation

/// Reads the de-facto subscription headers used by Clash-compatible panels.
/// The values are only shown locally; nothing is uploaded.
enum SubscriptionHeader {
    struct Metadata {
        var subscription: Profile.Subscription
        var suggestedName: String?
    }

    nonisolated static func parse(headers: [String: String], now: Date = Date()) -> Metadata {
        func header(_ name: String) -> String? {
            headers[name.lowercased()]?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var subscription = Profile.Subscription()
        subscription.lastUpdated = now

        if let userInfo = header("subscription-userinfo") {
            for item in userInfo.split(separator: ";") {
                let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: true)
                guard pair.count == 2 else { continue }
                let key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
                let value = pair[1].trimmingCharacters(in: .whitespaces)
                switch key {
                case "upload": subscription.upload = UInt64(value)
                case "download": subscription.download = UInt64(value)
                case "total": subscription.total = UInt64(value)
                case "expire":
                    if let seconds = Int64(value), seconds > 0 {
                        let unix = seconds > 10_000_000_000 ? seconds / 1000 : seconds
                        subscription.expire = Date(timeIntervalSince1970: TimeInterval(unix))
                    }
                default: continue
                }
            }
        }

        if let interval = header("profile-update-interval"),
           let value = leadingInteger(interval), value > 0 {
            // Most panels publish hours; some publish minutes. Values above a
            // week are treated as minutes.
            let hours = value > 168 ? max(1, value / 60) : value
            subscription.updateIntervalHours = min(max(hours, 1), 720)
        }

        subscription.webPageURL = header("profile-web-page-url")

        let name = header("profile-title").flatMap(decodeTitle)
            ?? header("content-disposition").flatMap(fileName(in:))

        return Metadata(subscription: subscription, suggestedName: name)
    }

    nonisolated private static func leadingInteger(_ text: String) -> Int? {
        var digits = ""
        for character in text {
            if character.isNumber {
                digits.append(character)
            } else if !digits.isEmpty {
                break
            }
        }
        return Int(digits)
    }

    nonisolated private static func decodeTitle(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("base64:") {
            let encoded = String(trimmed.dropFirst("base64:".count))
            guard let data = Data(base64Encoded: encoded, options: [.ignoreUnknownCharacters]),
                  let decoded = String(data: data, encoding: .utf8) else {
                return nil
            }
            return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    nonisolated private static func fileName(in disposition: String) -> String? {
        for component in disposition.split(separator: ";") {
            let pair = component.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: true)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            guard key == "filename" || key == "filename*" else { continue }
            var value = pair[1].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            if let separator = value.range(of: "''") {
                value = String(value[separator.upperBound...])
            }
            if let decoded = value.removingPercentEncoding, !decoded.isEmpty {
                return decoded
            }
            if !value.isEmpty { return value }
        }
        return nil
    }
}
