import SwiftUI
import NetworkExtension

struct DNSDiagnosticsView: View {
    let vpn: PrototypeVPN
    @State private var domain = ""
    @State private var type = "A"
    @State private var running = false
    @State private var answer: String?
    @State private var explanation: String?

    var body: some View {
        Form {
            Section("查询") {
                TextField("域名", text: $domain)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker("记录类型", selection: $type) {
                    ForEach(["A", "AAAA", "CNAME", "TXT", "MX"], id: \.self) { Text($0).tag($0) }
                }
                Button("查询与解释") { Task { await run() } }
                    .disabled(running || vpn.status != .connected ||
                              domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if running { ProgressView() }
            }
            if let answer {
                Section("解析结果") { Text(answer).textSelection(.enabled).font(.system(.footnote, design: .monospaced)) }
            }
            if let explanation {
                Section("策略解释") { Text(explanation).textSelection(.enabled).font(.system(.footnote, design: .monospaced)) }
            }
        }
        .navigationTitle("DNS 排查")
    }

    private func run() async {
        running = true
        defer { running = false }
        do {
            let result = try await vpn.live.diagnoseDNS(
                name: domain.trimmingCharacters(in: .whitespacesAndNewlines), type: type
            )
            answer = result.0
            explanation = result.1
        } catch {
            answer = error.localizedDescription
            explanation = nil
        }
    }
}
