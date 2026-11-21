import SwiftUI

struct PasteConfiguration: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var name: String
    @State private var text = ""
    @State private var error: String?
    let parse: (String) -> String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("配置名称（可选）", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("paste-name")
                } footer: {
                    Text("留空时使用默认名称。")
                }
                TextEditor(text: $text)
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .frame(minHeight: 200)
                    .accessibilityLabel("配置内容")
                if let error { Text(error).foregroundStyle(.orange) }
            }
            .navigationTitle("粘贴配置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("预览") {
                        error = parse(text)
                        if error == nil { dismiss() }
                    }
                    .disabled(text.isEmpty)
                }
            }
        }
    }
}

#if DEBUG
#Preview("粘贴配置") {
    PasteConfiguration(name: .constant("")) { _ in nil }
}
#endif
