import SwiftUI

struct URLImport: View {
    @Environment(\.dismiss) private var dismiss
    let vpn: PrototypeVPN
    @Binding var name: String
    @State private var text = ""
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("配置名称（可选）", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("url-name")
                } footer: {
                    Text("留空时使用默认名称。")
                }
                Section {
                    TextField("https://example.com/config.yaml", text: $text)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("url-field")
                } footer: {
                    Text("仅支持 HTTPS，上限 8 MB。支持 Clash YAML、base64 订阅和分享链接；链接保存在本机用于手动或自动更新，不会写入诊断。")
                }
                if let error {
                    Text(error).foregroundStyle(.orange)
                }
                if loading {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("正在下载…")
                    }
                }
            }
            .navigationTitle("从 URL 导入")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("下载并预览") {
                        Task {
                            loading = true
                            error = nil
                            let success = await vpn.importURL(text)
                            loading = false
                            if success {
                                dismiss()
                            } else {
                                error = vpn.importError
                            }
                        }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loading)
                    .accessibilityIdentifier("url-download")
                }
            }
        }
    }
}

#if DEBUG
#Preview("从 URL 导入") {
    URLImport(vpn: .preview(), name: .constant(""))
}
#endif
