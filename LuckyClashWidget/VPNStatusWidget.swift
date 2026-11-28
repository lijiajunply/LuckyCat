import AppIntents
import SwiftUI
import WidgetKit

private struct VPNStatusEntry: TimelineEntry {
    let date: Date
    let status: VPNWidgetStatus
    let updatedAt: Date?
    var group: String? = nil
    var node: String? = nil

    var expiration: Date? {
        guard status == .connecting || status == .disconnecting else { return nil }
        return updatedAt?.addingTimeInterval(10 * 60)
    }
}

private struct VPNStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> VPNStatusEntry {
        VPNStatusEntry(date: .now, status: .connected, updatedAt: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (VPNStatusEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<VPNStatusEntry>) -> Void) {
        let entry = currentEntry()
        var entries = [entry]
        if let expiration = entry.expiration {
            entries.append(VPNStatusEntry(date: expiration, status: .unknown, updatedAt: nil))
        }
        completion(Timeline(entries: entries, policy: .after(entry.date.addingTimeInterval(30 * 60))))
    }

    private func currentEntry() -> VPNStatusEntry {
        let snapshot = VPNWidgetStatus.snapshot()
        let entry = VPNStatusEntry(
            date: .now, status: snapshot?.status ?? .unknown, updatedAt: snapshot?.updatedAt,
            group: snapshot?.group, node: snapshot?.node
        )
        if let expiration = entry.expiration, expiration <= entry.date {
            return VPNStatusEntry(date: entry.date, status: .unknown, updatedAt: nil)
        }
        return entry
    }
}

private struct VPNStatusView: View {
    @Environment(\.widgetFamily) private var family
    let entry: VPNStatusEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                Label(title, systemImage: symbol)
            case .accessoryRectangular:
                VStack(alignment: .leading) {
                    Text("LuckyClash").font(.caption)
                    Label(title, systemImage: symbol).font(.headline)
                    if let route { Text(route).font(.caption).privacySensitive() }
                    controlButton
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            default:
                homeScreenView
            }
        }
        .widgetURL(VPNWidgetStatus.connectionURL)
        .containerBackground(for: .widget) { Color(.systemBackground) }
    }

    private var homeScreenView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("LuckyClash", systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .widgetAccentable()
            Spacer(minLength: 4)
            Text(title)
                .font(.title2.bold())
            if let route {
                Text(route).font(.caption).foregroundStyle(.secondary).privacySensitive()
            } else if let updatedAt = entry.updatedAt, entry.status != .unknown {
                Text("更新于 \(updatedAt, style: .relative)前")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("打开应用查看状态")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            controlButton
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    @ViewBuilder private var controlButton: some View {
        if #available(iOS 18.0, *), entry.status == .connected || entry.status == .disconnected {
            Button(intent: SetVPNControlIntent(value: entry.status == .disconnected)) {
                Label(entry.status == .connected ? "断开" : "连接", systemImage: "power")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
        }
    }

    private var route: String? {
        let components = [entry.group, entry.node].compactMap { $0 }.filter { !$0.isEmpty }
        return components.isEmpty ? nil : components.joined(separator: " → ")
    }

    private var title: LocalizedStringKey {
        switch entry.status {
        case .connected: "已连接"
        case .connecting: "连接中"
        case .disconnecting: "断开中"
        case .disconnected: "未连接"
        case .unknown: "状态未知"
        }
    }

    private var symbol: String {
        switch entry.status {
        case .connected: "checkmark.shield.fill"
        case .connecting, .disconnecting: "arrow.clockwise"
        case .disconnected: "bolt.slash"
        case .unknown: "questionmark.circle"
        }
    }

    private var tint: Color {
        switch entry.status {
        case .connected: .green
        case .connecting, .disconnecting: .orange
        case .disconnected, .unknown: .secondary
        }
    }
}

struct VPNStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: VPNWidgetStatus.kind, provider: VPNStatusProvider()) { entry in
            VPNStatusView(entry: entry)
        }
        .configurationDisplayName("VPN 连接状态")
        .description("查看 LuckyClash 最近一次更新的 VPN 状态，轻点即可打开连接页。")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct LuckyClashWidgetBundle: WidgetBundle {
    var body: some Widget {
        VPNStatusWidget()
        if #available(iOS 18.0, *) {
            VPNControlWidget()
        }
    }
}
