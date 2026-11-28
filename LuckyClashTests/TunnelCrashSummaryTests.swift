import Testing
@testable import LuckyClash

struct TunnelCrashSummaryTests {
    @Test func identifiesCrashWithoutExportingRawText() {
        let report = "fatal error: concurrent map writes\nprivate-token-example"
        let summary = TunnelDiagnosticEvents.crashSummary(report)
        #expect(summary.contains("并发映射"))
        #expect(!summary.contains("private-token-example"))
        #expect(summary == TunnelDiagnosticEvents.crashSummary(report))
        #expect(summary != TunnelDiagnosticEvents.crashSummary(report + "x"))
    }
}
