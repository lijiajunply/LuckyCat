import SwiftUI

struct SubscriptionManagementView: View {
    let vpn: PrototypeVPN
    let onShowDetail: (UUID) -> Void
    private var subscriptions: [Profile] { vpn.library.profiles.filter { $0.sourceURL != nil } }

    var body: some View {
        List {
            Section {
                if subscriptions.isEmpty {
                    Text("暂无订阅配置").foregroundStyle(.secondary)
                }
                ForEach(subscriptions) { profile in
                    Button { onShowDetail(profile.id) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile.name)
                            Text(profile.subscription?.lastUpdated.map { "更新于 \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "尚无更新时间")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }.foregroundStyle(.primary)
                }
                Button {
                    Task { await vpn.updateAll() }
                } label: {
                    if vpn.updatingProfileID != nil {
                        ProgressView("正在更新订阅…")
                    } else {
                        Label("更新全部订阅", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(subscriptions.isEmpty || vpn.busy || vpn.isActive)
            } footer: {
                Text("打开 App 或回到前台时，会尝试更新已到期且开启自动更新的订阅。更新前请断开 VPN。")
            }
        }
        .navigationTitle("订阅管理")
    }
}
