import SwiftUI

/// The full answer from the IP lookup behind the connection page's detection
/// card: identity, type and risk flags, plus the service that answered.
struct OutboundIPDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let detection: OutboundIPDetection

    @AppStorage("hideOutboundIP") private var hideIP = false

    var body: some View {
        NavigationStack {
            List {
                if let report = detection.report {
                    basics(report)
                    network(report)
                }
                if let failure = detection.failure {
                    sources(failure)
                }
                if detection.report == nil && detection.failure == nil {
                    Section {
                        HStack(spacing: 8) {
                            if detection.isChecking {
                                ProgressView()
                            }
                            Text(detection.isChecking ? "正在检测出口 IP…" : "尚未检测")
                        }
                    }
                }
                Section {
                    Toggle("隐藏 IP", isOn: $hideIP)
                } footer: {
                    Text("隐藏只影响本机显示，不改变实际出口。")
                }
            }
            .navigationTitle("出站 IP")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        detection.refresh()
                    } label: {
                        if detection.isChecking {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(detection.isChecking)
                    .accessibilityLabel("重新查询")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func basics(_ report: OutboundIPReport) -> some View {
        Section {
            LabeledContent("IP 地址") {
                Text(hideIP ? "••••••••" : report.ip)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            }
            LabeledContent("等级") {
                Text(LocalizedStringKey(report.quality.title))
                    .foregroundStyle(color(report.quality))
            }
            LabeledContent("类型") { Text(LocalizedStringKey(report.kind.title)) }
            LabeledContent("命中标记", value: report.flags.isEmpty ? "无" : report.flags.joined(separator: "、"))
            if !report.countryName.isEmpty {
                LabeledContent("国家/地区", value: country(report))
            }
        } header: {
            Text("基础信息")
        } footer: {
            Text("依赖第三方 API，仅供参考。")
        }
    }

    private func network(_ report: OutboundIPReport) -> some View {
        Section("网络") {
            LabeledContent("组织", value: report.organization ?? "—")
            LabeledContent("ASN", value: report.asn.map { "AS\($0)" } ?? "—")
            LabeledContent("采用来源", value: report.source)
            LabeledContent(
                "检测时间",
                value: report.checkedAt.formatted(date: .omitted, time: .standard)
            )
        }
    }

    private func sources(_ failure: OutboundIPFailure) -> some View {
        Section {
            ForEach(failure.failures, id: \.source) { item in
                LabeledContent(item.source, value: item.reason)
            }
        } header: {
            Text("各来源")
        } footer: {
            Text("请检查网络连接，或稍后重新查询。")
        }
    }

    private func country(_ report: OutboundIPReport) -> String {
        guard let code = report.countryCode else { return report.countryName }
        return "\(report.countryName)（\(code)）"
    }

    private func color(_ quality: OutboundIPReport.Quality) -> Color {
        switch quality {
        case .good: .green
        case .normal: .secondary
        case .risky: .red
        }
    }
}

#if DEBUG
#Preview("出站 IP") {
    OutboundIPDetailView(detection: .preview(PreviewSamples.outboundIP))
}

#Preview("出站 IP · 检测失败") {
    OutboundIPDetailView(detection: .preview(failure: OutboundIPFailure(failures: [
        .init(source: "ipquery.io", reason: "请求超时"),
        .init(source: "ident.me", reason: "无法连接"),
    ])))
}
#endif
