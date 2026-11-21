import SwiftUI

/// Local diagnostics history, reachable from the settings page.
struct DiagnosticsView: View {
    let log: DiagnosticLog
    @State private var showingClear = false

    var body: some View {
        List {
            if log.records.isEmpty {
                Text("暂无诊断记录。").foregroundStyle(.secondary)
            } else {
                Section {
                    ForEach(log.records.reversed()) { record in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.event)
                            Text(record.timestamp.formatted(date: .abbreviated, time: .standard))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("最近 \(log.records.count) 条")
                }
                Section {
                    ShareLink(item: log.exportText) {
                        Label("导出诊断", systemImage: "square.and.arrow.up")
                    }
                    Button("清除记录", role: .destructive) { showingClear = true }
                } footer: {
                    Text("记录保留 7 天，最多 200 条。仅含事件、错误码与时间，不含密钥、订阅链接、访问目标或包内容。")
                }
            }
        }
        .navigationTitle("本地诊断")
        .alert("清除诊断记录？", isPresented: $showingClear) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) { log.clear() }
        } message: {
            Text("将删除本机保存的全部诊断记录。")
        }
    }
}

#if DEBUG
#Preview("本地诊断") {
    NavigationStack {
        DiagnosticsView(log: PreviewSamples.diagnosticLog())
    }
}
#endif
