import NetworkExtension
import SwiftUI

/// Human-readable status values shared by the connection page and the
/// connection information sheet.
enum VPNStatusText {
    static func status(_ vpn: PrototypeVPN) -> String {
        if vpn.requestingConnection { return "正在请求连接" }
        if vpn.isActive && !vpn.canStop { return "断开中" }
        switch vpn.status {
        case .invalid: return vpn.library.selectedProfile == nil ? "未配置" : "已断开"
        case .disconnected: return "已断开"
        case .connecting: return "连接中"
        case .connected: return "已连接"
        case .reasserting: return "重连中"
        case .disconnecting: return "断开中"
        @unknown default: return "未知"
        }
    }

    static func extensionStatus(_ vpn: PrototypeVPN) -> String {
        switch vpn.extensionReady {
        case true?: "已就绪"
        case false?: "未就绪"
        case nil: "暂不可用"
        }
    }

    static func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .binary)
    }
}

extension TrafficMode {
    var title: String {
        switch self {
        case .rule: "规则"
        case .global: "全局"
        case .direct: "直连"
        }
    }

    var explanation: String {
        switch self {
        case .rule: "按配置中的规则分流，未匹配的流量使用 MATCH 策略。"
        case .global: "忽略规则，所有流量都通过当前代理组。"
        case .direct: "不经过代理，所有流量直接连接。"
        }
    }
}

/// The technical view of the current session, condensed from the connection
/// and profile pages behind one info button.
struct ConnectionInfoView: View {
    @Environment(\.dismiss) private var dismiss
    let vpn: PrototypeVPN

    private var profile: Profile? { vpn.library.selectedProfile }

    var body: some View {
        NavigationStack {
            List {
                statusSection
                if let profile {
                    profileSection(profile)
                    if profile.sourceURL != nil {
                        subscriptionSection(profile)
                    }
                    overviewSection(profile)
                }
                if let message = vpn.message {
                    Section {
                        MessageLabel(text: message)
                    }
                }
            }
            .navigationTitle("连接信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var statusSection: some View {
        Section {
            LabeledContent("VPN", value: VPNStatusText.status(vpn))
            if vpn.isActive {
                LabeledContent("扩展", value: VPNStatusText.extensionStatus(vpn))
            }
            LabeledContent("分流模式", value: vpn.library.trafficMode.title)
            if vpn.isActive, let traffic = vpn.traffic {
                LabeledContent("接收", value: VPNStatusText.bytes(traffic.received))
                LabeledContent("发送", value: VPNStatusText.bytes(traffic.sent))
                LabeledContent(
                    "更新",
                    value: traffic.updatedAt.formatted(date: .omitted, time: .standard)
                )
            }
        } header: {
            Text("运行状态")
        } footer: {
            Text("流量由扩展每 5 秒聚合上报，仅显示在本机。")
        }
    }

    @ViewBuilder private func profileSection(_ profile: Profile) -> some View {
        Section("当前配置") {
            LabeledContent("配置", value: profile.name)
            if let node = profile.selectedNode {
                LabeledContent("节点", value: node.name)
                if let type = node.type, !type.isEmpty {
                    LabeledContent("协议", value: type)
                }
                if !node.endpoint.isEmpty {
                    LabeledContent("远端", value: node.endpoint)
                }
            }
            if let group = profile.clashGroup, !group.isEmpty {
                LabeledContent("策略组", value: group)
            }
            if let source = profile.sourceURL {
                LabeledContent("来源", value: source.host() ?? "链接")
            }
            if let updated = profile.subscription?.lastUpdated {
                LabeledContent(
                    "上次更新",
                    value: updated.formatted(date: .abbreviated, time: .shortened)
                )
            }
            if let tested = vpn.latencyTestedAt[profile.id] {
                LabeledContent(
                    "上次测速",
                    value: tested.formatted(date: .omitted, time: .shortened)
                )
            }
            if vpn.latencyTesting, vpn.latencyProfileID == profile.id {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在测试节点延迟…")
                }
            }
        }
    }

    @ViewBuilder private func subscriptionSection(_ profile: Profile) -> some View {
        Section("订阅") {
            if let subscription = profile.subscription {
                LabeledContent("流量", value: ImportSummary.flow(subscription))
                LabeledContent("到期", value: ImportSummary.expiry(subscription.expire))
            }
            LabeledContent("自动更新", value: profile.autoUpdateEnabled ? "已开启" : "已关闭")
        }
    }

    @ViewBuilder private func overviewSection(_ profile: Profile) -> some View {
        Section("配置概况") {
            LabeledContent("策略组", value: "\(profile.clashGroups?.count ?? 0) 个")
            LabeledContent("节点", value: "\(profile.nodes.count) 个")
            if let rules = profile.rules, !rules.isEmpty {
                LabeledContent("规则", value: "\(rules.count) 条")
            }
            if !profile.nodes.isEmpty {
                NavigationLink("兼容提示") {
                    ProfileCompatibility(profile: profile)
                }
            }
        }
    }
}
