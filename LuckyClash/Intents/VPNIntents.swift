import AppIntents
import Foundation
import NetworkExtension

private enum IntentFailure: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self { case .message(let value): value }
    }
}

private enum IntentVPN {
    @MainActor static func ready() async throws -> PrototypeVPN {
        let vpn = LuckyClashApp.vpn
        await vpn.refresh()
        guard !vpn.busy, !vpn.switchingProfile else {
            throw IntentFailure.message("VPN 正在处理其他操作，请稍后重试。")
        }
        return vpn
    }

    @MainActor static func waitForRoute(_ vpn: PrototypeVPN) async throws {
        let deadline = ContinuousClock.now + .seconds(35)
        while vpn.routeChangesInFlight > 0 || vpn.busy || vpn.switchingProfile {
            guard ContinuousClock.now < deadline else { throw IntentFailure.message("操作超时，请查看应用中的连接状态。") }
            try await Task.sleep(for: .milliseconds(100))
        }
        if let message = vpn.message {
            throw IntentFailure.message(message)
        }
    }
}

struct ConnectVPNIntent: AppIntent {
    static let title: LocalizedStringResource = "连接 LuckyClash"
    static let description = IntentDescription("使用当前选择的配置连接 VPN。")
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        guard UserDefaults.standard.integer(forKey: "tunnelDisclosureVersion") == 1 else {
            throw IntentFailure.message("请先在 LuckyClash 中查看并同意 VPN 数据使用说明。")
        }
        let vpn = try await IntentVPN.ready()
        if vpn.isActive { return .result() }
        guard vpn.library.selectedProfile != nil else {
            throw IntentFailure.message("请先在 LuckyClash 中选择配置。")
        }
        await vpn.connect()
        guard vpn.isActive else { throw IntentFailure.message(vpn.message ?? "无法发起 VPN 连接。") }
        return .result()
    }
}

struct DisconnectVPNIntent: AppIntent {
    static let title: LocalizedStringResource = "断开 LuckyClash"
    static let description = IntentDescription("断开当前 VPN 连接。")
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        let vpn = try await IntentVPN.ready()
        guard vpn.isActive else { return .result() }
        guard vpn.canStop else { throw IntentFailure.message("VPN 正在断开，请稍后重试。") }
        vpn.disconnect()
        let deadline = ContinuousClock.now + .seconds(30)
        repeat {
            try await Task.sleep(for: .milliseconds(150))
            await vpn.updateStatus()
        } while vpn.isActive && ContinuousClock.now < deadline
        guard !vpn.isActive else { throw IntentFailure.message(vpn.message ?? "断开连接超时。") }
        return .result()
    }
}

enum IntentTrafficMode: String, AppEnum {
    case rule, global, direct
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "分流模式"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .rule: "规则", .global: "全局", .direct: "直连"
    ]
}

struct SetVPNModeIntent: AppIntent {
    static let title: LocalizedStringResource = "切换 LuckyClash 分流模式"
    static let openAppWhenRun = true
    @Parameter(title: "模式") var mode: IntentTrafficMode

    @MainActor func perform() async throws -> some IntentResult {
        let vpn = try await IntentVPN.ready()
        guard let value = TrafficMode(rawValue: mode.rawValue), vpn.library.selectedProfile != nil else {
            throw IntentFailure.message("请先在 LuckyClash 中选择配置。")
        }
        vpn.setMode(value)
        try await IntentVPN.waitForRoute(vpn)
        return .result()
    }
}

struct SelectVPNGroupIntent: AppIntent {
    static let title: LocalizedStringResource = "选择 LuckyClash 策略组节点"
    static let openAppWhenRun = true
    @Parameter(title: "策略组名称") var group: String
    @Parameter(title: "成员名称") var member: String

    @MainActor func perform() async throws -> some IntentResult {
        let vpn = try await IntentVPN.ready()
        guard let profile = vpn.library.selectedProfile,
              let selectedGroup = profile.clashGroups?.first(where: { $0.name == group }),
              selectedGroup.isSelectable || selectedGroup.canPin,
              vpn.members(for: selectedGroup, profileID: profile.id).contains(member),
              vpn.canSwitchNodes(for: profile.id) else {
            throw IntentFailure.message("找不到可切换的策略组或成员。")
        }
        vpn.selectMember(profileID: profile.id, group: selectedGroup, member: member)
        try await IntentVPN.waitForRoute(vpn)
        return .result()
    }
}

struct LuckyClashShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ConnectVPNIntent(), phrases: ["用 \(.applicationName) 连接 VPN"], shortTitle: "连接 VPN", systemImageName: "bolt.shield")
        AppShortcut(intent: DisconnectVPNIntent(), phrases: ["用 \(.applicationName) 断开 VPN"], shortTitle: "断开 VPN", systemImageName: "bolt.slash")
    }
}
