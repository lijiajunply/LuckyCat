import SwiftUI
import UniformTypeIdentifiers

private struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw BackupEncryption.Failure.invalidBackup
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct BackupRestoreView: View {
    let vpn: PrototypeVPN
    @State private var password = ""
    @State private var document: BackupDocument?
    @State private var exporting = false
    @State private var importing = false
    @State private var confirmingRestore = false
    @State private var selectedURL: URL?
    @State private var restoring = false
    @State private var webDAVURL = ""
    @State private var webDAVUsername = ""
    @State private var webDAVPassword = ""
    @State private var downloadedBackup: Data?
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                SecureField("备份密码", text: $password)
                    .textContentType(.password)
                Button("导出加密备份", systemImage: "square.and.arrow.up") {
                    do {
                        document = BackupDocument(data: try vpn.exportBackup(password: password))
                        exporting = true
                        message = nil
                    } catch { message = error.localizedDescription }
                }
                .disabled(password.isEmpty || vpn.busy || vpn.switchingProfile)
                Button("选择备份恢复", systemImage: "square.and.arrow.down") { importing = true }
                    .disabled(password.isEmpty || vpn.isActive || vpn.busy || vpn.switchingProfile || restoring)
            } footer: {
                Text("备份包含配置与节点凭据，使用密码加密。文件可保存到本机或 iCloud Drive。恢复会替换当前配置列表，请先断开 VPN。")
            }
            Section {
                TextField("HTTPS 文件地址", text: $webDAVURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("用户名", text: $webDAVUsername)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("WebDAV 密码", text: $webDAVPassword)
                Button("上传加密备份") { Task { await upload() } }
                    .disabled(password.isEmpty || webDAVURL.isEmpty || vpn.busy || vpn.switchingProfile || restoring)
                Button("下载备份并恢复") { Task { await download() } }
                    .disabled(password.isEmpty || webDAVURL.isEmpty || vpn.isActive || vpn.busy || vpn.switchingProfile || restoring)
            } header: {
                Text("WebDAV")
            }
            if restoring { ProgressView("正在处理…") }
            if let message { Text(message).foregroundStyle(.secondary) }
        }
        .navigationTitle("备份与恢复")
        .fileExporter(isPresented: $exporting, document: document, contentType: .json,
                      defaultFilename: "LuckyClash-Backup") { result in
            if case .failure(let error) = result { message = error.localizedDescription }
            document = nil
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                selectedURL = url
                confirmingRestore = true
            case .failure(let error): message = error.localizedDescription
            }
        }
        .alert("恢复备份？", isPresented: $confirmingRestore) {
            Button("取消", role: .cancel) { selectedURL = nil; downloadedBackup = nil }
            Button("恢复", role: .destructive) { restore() }
        } message: {
            Text("当前配置列表和偏好设置将被备份内容替换。系统按需连接会暂停，重新连接时应用恢复后的设置。")
        }
    }

    private func restore() {
        let url = selectedURL
        let downloaded = downloadedBackup
        selectedURL = nil
        downloadedBackup = nil
        restoring = true
        Task {
            defer { restoring = false }
            do {
                let data: Data
                if let downloaded {
                    data = downloaded
                } else if let url {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let file = try FileHandle(forReadingFrom: url)
                    defer { try? file.close() }
                    data = try file.read(upToCount: BackupEncryption.maximumSize * 2 + 1) ?? Data()
                } else { throw BackupEncryption.Failure.invalidBackup }
                guard data.count <= BackupEncryption.maximumSize * 2 else {
                    throw BackupEncryption.Failure.invalidBackup
                }
                try await vpn.restoreBackup(data, password: password)
                password = ""
                message = "备份已恢复。"
            } catch { message = error.localizedDescription }
        }
    }
    private func upload() async {
        guard let url = URL(string: webDAVURL) else { message = "请输入有效地址。"; return }
        restoring = true
        defer { restoring = false }
        do {
            let data = try vpn.exportBackup(password: password)
            try await BackupWebDAV.upload(data, to: url, username: webDAVUsername, password: webDAVPassword)
            message = "加密备份已上传。"
        } catch { message = error.localizedDescription }
    }

    private func download() async {
        guard let url = URL(string: webDAVURL) else { message = "请输入有效地址。"; return }
        restoring = true
        defer { restoring = false }
        do {
            downloadedBackup = try await BackupWebDAV.download(from: url, username: webDAVUsername, password: webDAVPassword)
            confirmingRestore = true
        } catch { message = error.localizedDescription }
    }

}
