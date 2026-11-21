import SwiftUI

struct MessageLabel: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.circle")
            .foregroundStyle(.orange)
            .font(.footnote)
    }
}

#if DEBUG
#Preview("提示文字") {
    List {
        MessageLabel(text: "iOS 未启动连接，请检查系统 VPN 设置。")
        MessageLabel(text: "正在准备 GeoIP 数据…")
    }
}
#endif
