import NetworkExtension
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    enum Page: Hashable { case connection, network, profiles, settings }

    @Environment(\.scenePhase) private var scenePhase
    @State private var vpn: PrototypeVPN
    @State private var page: Page
    @State private var showingImporter = false
    @State private var showingPaste = false
    @State private var showingURLImport = false
    @State private var showingQRImport = false
    @State private var pendingQRPayload: String?
    @State private var pendingImportName = ""
    @State private var showingPreview = false
    @State private var pendingDeletion: Profile?
    @State private var detailProfileID: UUID?
    @State private var showingInfo = false

    /// The defaults keep the app entry point unchanged (`ContentView()`); the
    /// parameters exist so previews can open a specific page with seeded state.
    init(vpn: PrototypeVPN = PrototypeVPN(), page: Page = .connection) {
        _vpn = State(initialValue: vpn)
        _page = State(initialValue: page)
    }

    var body: some View {
        TabView(selection: $page) {
            ConnectionPage(
                vpn: vpn,
                onImportFile: {
                    pendingImportName = ""
                    showingImporter = true
                },
                onPaste: {
                    pendingImportName = ""
                    showingPaste = true
                },
                onImportURL: {
                    pendingImportName = ""
                    vpn.discardImport()
                    showingURLImport = true
                },
                onImportQR: {
                    pendingImportName = ""
                    showingQRImport = true
                },
                onShowDetail: { detailProfileID = $0 },
                onDelete: { pendingDeletion = $0 },
                onShowProfiles: { page = .profiles }
            )
            .tabItem { Label("连接", systemImage: "bolt.shield") }
            .tag(Page.connection)
            ProfilesView(
                vpn: vpn,
                onShowDetail: { detailProfileID = $0 },
                onDelete: { pendingDeletion = $0 },
                onShowConnection: { page = .connection },
                onShowInfo: { showingInfo = true }
            )
            .tabItem { Label("配置", systemImage: "folder") }
            .tag(Page.profiles)
            NetworkPage(vpn: vpn)
                .tabItem { Label("网络", systemImage: "waveform.path.ecg") }
                .tag(Page.network)
            SettingsPage(vpn: vpn, onShowProfile: { detailProfileID = $0 })
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(Page.settings)
        }
        .toast(vpn.toast, enabled: detailProfileID == nil && !showingInfo)
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.yaml, .json, .plainText]) { result in
            switch result {
            case .success(let url):
                vpn.importFile(url)
                showingPreview = vpn.hasStagedImport
                if !showingPreview, let error = vpn.importError {
                    vpn.showToast(error)
                }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError {
                    vpn.showToast("无法打开配置文件。")
                }
            }
        }
        .sheet(isPresented: $showingPaste, onDismiss: presentStagedPreview) {
            PasteConfiguration(name: $pendingImportName) { text in
                vpn.stage(Data(text.utf8))
                return vpn.imported.isEmpty ? vpn.importError : nil
            }
        }
        .sheet(isPresented: $showingURLImport, onDismiss: presentStagedPreview) {
            URLImport(vpn: vpn, name: $pendingImportName)
        }
        .fullScreenCover(isPresented: $showingQRImport, onDismiss: importQRCode) {
            QRCodeImportView { code in
                pendingQRPayload = code
                showingQRImport = false
            }
        }
        .sheet(isPresented: $showingPreview, onDismiss: vpn.discardImport) {
            if let first = vpn.imported.first {
                ImportPreview(vpn: vpn, selectedNode: first.id, initialName: pendingImportName)
            } else {
                ImportPreview(vpn: vpn, selectedNode: "", initialName: pendingImportName)
            }
        }
        .sheet(isPresented: Binding(
            get: { detailProfileID != nil },
            set: { if !$0 { detailProfileID = nil } }
        )) {
            if let detailProfileID {
                ProfileDetailView(vpn: vpn, profileID: detailProfileID)
            }
        }
        .sheet(isPresented: $showingInfo) {
            ConnectionInfoView(vpn: vpn)
        }
        .alert("删除配置？", isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        ), presenting: pendingDeletion) { profile in
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { Task { await vpn.remove(profile) } }
        } message: { profile in
            Text("将从本机删除「\(profile.name)」及其节点凭据。")
        }
        .onChange(of: scenePhase, initial: true) {
            guard scenePhase == .active else { return }
            Task {
                await vpn.refresh()
                await vpn.updateDueProfiles()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NEVPNStatusDidChange)) { _ in
            Task { await vpn.updateStatus() }
        }
        .onOpenURL { url in
            handleOpenURL(url)
        }
    }

    private func handleOpenURL(_ url: URL) {
        if url == VPNWidgetStatus.connectionURL {
            page = .connection
            return
        }
        // Subscription links use clash://install-config or luckyclash://install-config.
        guard ["clash", "luckyclash"].contains(url.scheme?.lowercased() ?? "") else { return }
        let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "url" })?.value
        guard let target, RemoteImport.url(from: target) != nil else { return }
        page = .profiles
        pendingImportName = ""
        vpn.discardImport()
        Task {
            if await vpn.importURL(target) {
                showingPreview = true
            } else if let error = vpn.importError {
                vpn.showToast(error)
            }
        }
    }

    /// Opens the import preview once the source sheet has finished
    /// dismissing; presenting a second sheet during dismissal is unreliable.
    private func presentStagedPreview() {
        guard vpn.hasStagedImport else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            showingPreview = true
        }
    }

    private func importQRCode() {
        guard let payload = pendingQRPayload else { return }
        pendingQRPayload = nil
        pendingImportName = ""
        vpn.discardImport()
        if let url = QRCodePayload.subscriptionURL(from: payload) {
            Task {
                if await vpn.importURL(url.absoluteString) {
                    try? await Task.sleep(for: .milliseconds(250))
                    showingPreview = true
                } else {
                    vpn.message = vpn.importError
                }
            }
        } else {
            // Share links, a raw Clash YAML, or a base64 subscription bundle.
            vpn.stage(Data(payload.utf8))
            if vpn.hasStagedImport {
                showingPreview = true
            } else {
                vpn.message = vpn.importError ?? "二维码内容不是有效的配置链接。"
            }
        }
    }

}

#if DEBUG
// MARK: - Pages

#Preview("连接 · 已连接") {
    ContentView(
        vpn: .preview(
            status: .connected,
            traffic: PrototypeVPN.Traffic(
                received: 8_264_192, sent: 1_284_096, updatedAt: .now
            ),
            extensionReady: true,
            latencyResults: PreviewSamples.latencyResults(forProfile: PreviewSamples.profileID)
        ),
        page: .connection
    )
}

#Preview("连接 · 已断开") {
    ContentView(vpn: .preview(), page: .connection)
}

#Preview("连接 · 连接中") {
    ContentView(vpn: .preview(status: .connecting), page: .connection)
}

#Preview("连接 · 未配置") {
    ContentView(vpn: .preview(library: ProfileLibrary()), page: .connection)
}

#Preview("网络") {
    ContentView(vpn: .previewNetwork(), page: .network)
}

#Preview("配置") {
    ContentView(
        vpn: .preview(
            latencyResults: PreviewSamples.latencyResults(forProfile: PreviewSamples.profileID)
        ),
        page: .profiles
    )
}

#Preview("设置") {
    ContentView(vpn: .preview(), page: .settings)
}
#endif
