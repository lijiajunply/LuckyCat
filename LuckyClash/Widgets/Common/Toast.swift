import SwiftUI

struct ToastMessage: Equatable {
    let id = UUID()
    let text: String
    var isSuccess = false

    var duration: Duration {
        if isSuccess { return .seconds(3) }
        return .seconds(min(12, max(4, Double(text.count) / 10)))
    }
}

extension View {
    func toast(_ message: ToastMessage?, enabled: Bool = true) -> some View {
        modifier(ToastPresenter(message: message, enabled: enabled))
    }
}

private struct ToastPresenter: ViewModifier {
    let message: ToastMessage?
    let enabled: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visibleMessage: ToastMessage?
    @State private var bannerTextHeight: CGFloat?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if enabled, let visibleMessage {
                    toastContent(visibleMessage)
                        .padding(.horizontal, 16)
                        .padding(.top, visibleMessage.isSuccess ? 52 : 8)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: visibleMessage?.id)
            .onChange(of: message) {
                guard enabled, let message else { return }
                visibleMessage = message
                AccessibilityNotification.Announcement(message.text).post()
            }
            .onChange(of: enabled) {
                if !enabled { visibleMessage = nil }
            }
            .task(id: visibleMessage?.id) {
                guard let visibleMessage else { return }
                do {
                    try await Task.sleep(for: visibleMessage.duration)
                    if self.visibleMessage?.id == visibleMessage.id {
                        self.visibleMessage = nil
                    }
                } catch {
                    // A newer message or a dismissed presentation cancelled the timer.
                }
            }
    }

    @ViewBuilder private func toastContent(_ message: ToastMessage) -> some View {
        if message.isSuccess {
            Label(message.text, systemImage: "checkmark")
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                .allowsHitTesting(false)
        } else {
            banner(message.text)
        }
    }

    @ViewBuilder private func banner(_ text: String) -> some View {
        if text.contains(where: \.isNewline) {
            scrollableBanner(text)
        } else {
            ViewThatFits(in: .horizontal) {
                bannerFrame(alignment: .center) {
                    Text(text)
                        .fixedSize()
                }
                scrollableBanner(text)
            }
        }
    }

    private func scrollableBanner(_ text: String) -> some View {
        bannerFrame(alignment: .top) {
            ScrollView {
                Text(text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        geometry.size.height
                    } action: { height in
                        bannerTextHeight = height
                    }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(bannerTextHeight ?? 32, 96))
        }
        .frame(maxWidth: 360)
    }

    private func bannerFrame<Content: View>(
        alignment: VerticalAlignment, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: alignment, spacing: 12) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            content()
            Button {
                visibleMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .frame(minWidth: 32, minHeight: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("关闭提示")
        }
        .font(.subheadline)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.16), radius: 10, y: 3)
    }
}

#if DEBUG
#Preview("浮层提示") {
    @Previewable @State var message: ToastMessage?

    NavigationStack {
        List {
            Button("更新订阅") { message = ToastMessage(text: "订阅已更新", isSuccess: true) }
            Button("显示更新错误") {
                message = ToastMessage(text: "「花云」更新失败（HTTP 400）")
            }
            Button("显示批量更新错误") {
                let failures = (1...8).map { "订阅 \($0)：更新失败（HTTP 400），请检查链接。" }
                message = ToastMessage(text: failures.joined(separator: "\n"))
            }
        }
        .navigationTitle("订阅管理")
    }
    .toast(message)
}
#endif
