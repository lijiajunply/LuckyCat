import SwiftUI

struct SubscriptionRequestSettingsView: View {
    @AppStorage(RemoteImport.userAgentModeKey) private var userAgentMode = "default"
    @AppStorage(RemoteImport.customUserAgentKey) private var customUserAgent = ""
    @AppStorage(RemoteImport.verifyCertificateKey) private var verifyCertificate = true

    var body: some View {
        Form {
            Section {
                Picker("User-Agent", selection: $userAgentMode) {
                    Text("默认").tag("default")
                    Text("Clash.Meta").tag("meta")
                    Text("自定义").tag("custom")
                }
                if userAgentMode == "custom" {
                    TextField("User-Agent", text: $customUserAgent)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Toggle("校验服务器证书", isOn: $verifyCertificate)
            } header: {
                Text("订阅请求")
            } footer: {
                Text("证书校验设置适用于订阅导入与更新。关闭校验后连接可能被第三方冒充。")
            }
        }
        .navigationTitle("订阅请求")
    }
}
