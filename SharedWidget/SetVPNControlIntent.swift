import AppIntents
import Foundation

@available(iOS 18.0, *)
struct SetVPNControlIntent: SetValueIntent {
    static let title: LocalizedStringResource = "设置 VPN 连接"
    static let openAppWhenRun = true
    @Parameter(title: "连接") var value: Bool

    init() {}

    init(value: Bool) {
        self.value = value
    }

    @MainActor func perform() async throws -> some IntentResult {
        #if LUCKYCLASH_APP
        if value {
            _ = try await ConnectVPNIntent().perform()
        } else {
            _ = try await DisconnectVPNIntent().perform()
        }
        #else
        try ControlIntentError.requireApp()
        #endif
        return .result()
    }
}

private enum ControlIntentError: LocalizedError {
    case appRequired
    var errorDescription: String? { "请打开 LuckyClash 后重试。" }
    static func requireApp() throws { throw ControlIntentError.appRequired }
}
