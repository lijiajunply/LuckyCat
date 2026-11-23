import SwiftUI

struct SubscriptionManagementView: View {
    let vpn: PrototypeVPN
    @State private var selectedProfile: Profile?
    private var subscriptions: [Profile] { vpn.library.profiles.filter { $0.sourceURL != nil } }

    var body: some View {
        List {
            Section {
                if subscriptions.isEmpty {
                    Text("暂无订阅配置").foregroundStyle(.secondary)
                }
                ForEach(subscriptions) { profile in
                    Button { selectedProfile = profile } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile.name)
                            Text(profile.subscription?.lastUpdated.map { "更新于 \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "尚无更新时间")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }.foregroundStyle(.primary)
                }
                Button("更新全部订阅", systemImage: "arrow.clockwise") {
                    Task { await vpn.updateAll() }
                }.disabled(subscriptions.isEmpty || vpn.busy || vpn.isActive)
                if let message = vpn.message { MessageLabel(text: message) }
            } footer: {
                Text("自动更新在打开 App 时检查，不会在后台定时运行。更新前请断开 VPN。")
            }
        }
        .navigationTitle("订阅管理")
        .sheet(item: $selectedProfile) { profile in
            ProfileDetailView(vpn: vpn, profileID: profile.id)
        }
    }
}
