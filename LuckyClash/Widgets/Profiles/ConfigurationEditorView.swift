import SwiftUI

struct ConfigurationEditorView: View {
    let vpn: PrototypeVPN
    let profileID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var original = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("配置可能包含节点密码。保存时检查语法和基本结构；完整配置需连接时由内核验证。订阅更新会覆盖修改。")
                .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal)
            }
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .disabled(saving || vpn.isActive)
        }
        .navigationTitle("编辑配置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("保存") {
                guard let profile = vpn.library.profiles.first(where: { $0.id == profileID }) else { return }
                saving = true
                Task {
                    if await vpn.saveConfiguration(text, for: profile) { dismiss() }
                    else { error = vpn.message ?? "无法保存配置。" }
                    saving = false
                }
            }
            .disabled(text == original || text.isEmpty || saving || vpn.busy || vpn.isActive)
        }
        .task {
            do {
                guard let profile = vpn.library.profiles.first(where: { $0.id == profileID }) else { return }
                text = try vpn.configurationText(for: profile)
                original = text
            } catch { self.error = error.localizedDescription }
        }
    }
}
