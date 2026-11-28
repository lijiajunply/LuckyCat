import AppIntents
import SwiftUI
import WidgetKit

@available(iOS 18.0, *)
private struct VPNControlProvider: ControlValueProvider {
    var previewValue: Bool { false }

    func currentValue() async throws -> Bool {
        let status = VPNWidgetStatus.snapshot()?.status
        return status == .connected || status == .connecting
    }
}

@available(iOS 18.0, *)
struct VPNControlWidget: ControlWidget {
    static let kind = "LuckyClashVPNControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: VPNControlProvider()) { isOn in
            ControlWidgetToggle("LuckyClash", isOn: isOn, action: SetVPNControlIntent()) { active in
                Label(active ? "已连接" : "未连接", systemImage: active ? "bolt.shield.fill" : "bolt.slash")
            }
        }
        .displayName("VPN 连接")
        .description("打开 LuckyClash 并切换 VPN 连接。")
    }
}
