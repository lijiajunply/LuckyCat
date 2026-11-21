import SwiftUI

struct LatencyBadge: View {
    let state: LatencyState

    var body: some View {
        switch state {
        case .untested:
            EmptyView()
        case .testing:
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel("正在测试延迟")
        case .value(let delay):
            Text("\(delay) ms")
                .font(.caption.monospacedDigit())
                .foregroundStyle(color(for: delay))
                .accessibilityLabel("延迟 \(delay) 毫秒")
        case .failed:
            Text("超时")
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityLabel("延迟测试超时")
        }
    }

    private func color(for delay: Int) -> Color {
        switch delay {
        case ..<100: .green
        case ..<250: .orange
        default: .red
        }
    }
}

#if DEBUG
#Preview("延迟徽章") {
    List {
        LabeledContent("未测试") { LatencyBadge(state: .untested) }
        LabeledContent("测试中") { LatencyBadge(state: .testing) }
        LabeledContent("良好") { LatencyBadge(state: .value(38)) }
        LabeledContent("一般") { LatencyBadge(state: .value(180)) }
        LabeledContent("较差") { LatencyBadge(state: .value(420)) }
        LabeledContent("超时") { LatencyBadge(state: .failed) }
    }
}
#endif
