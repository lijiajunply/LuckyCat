import SwiftUI

struct ToastMessage: Equatable {
    let id = UUID()
    let text: String

    var duration: Duration {
        .seconds(min(12, max(4, Double(text.count) / 10)))
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

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if enabled, let visibleMessage {
                    banner(visibleMessage.text)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
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

    private func banner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            ViewThatFits(in: .vertical) {
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    Text(text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: 160, alignment: .topLeading)
            .layoutPriority(1)
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
        .frame(maxWidth: 480)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.16), radius: 10, y: 3)
    }
}

#if DEBUG
#Preview("浮层提示") {
    @Previewable @State var message: ToastMessage?

    NavigationStack {
        List {
            Button("更新订阅") { message = ToastMessage(text: "订阅更新成功。") }
        }
        .navigationTitle("订阅管理")
    }
    .toast(message)
}
#endif
