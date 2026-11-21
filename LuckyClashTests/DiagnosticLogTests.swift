import Foundation
import Testing
@testable import LuckyClash

@MainActor
struct DiagnosticLogTests {
    @Test func boundsRecordCountAndRetention() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var now = Date(timeIntervalSince1970: 1_000_000)
        let log = DiagnosticLog(fileURL: file, now: { now })

        for index in 0..<(DiagnosticLog.maximumRecords + 5) {
            log.append("事件 \(index)")
        }
        #expect(log.records.count == DiagnosticLog.maximumRecords)
        #expect(log.records.last?.event == "事件 \(DiagnosticLog.maximumRecords + 4)")

        now = now.addingTimeInterval(DiagnosticLog.retention + 1)
        log.append("新事件")
        #expect(log.records.map(\.event) == ["新事件"])
    }

    @Test func persistsRecordsAcrossInstances() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let date = Date(timeIntervalSince1970: 1_000_000)

        let first = DiagnosticLog(fileURL: file, now: { date })
        first.append("写入")
        first.append("第二行")

        let second = DiagnosticLog(fileURL: file, now: { date })
        #expect(second.records.map(\.event) == ["写入", "第二行"])

        second.clear()
        #expect(DiagnosticLog(fileURL: file, now: { date }).records.isEmpty)
    }

    @Test func sanitizesAndTruncatesEvents() {
        let log = DiagnosticLog(fileURL: nil, now: { Date(timeIntervalSince1970: 1_000_000) })
        log.append("第一行\n第二行\t结束")
        #expect(log.records.first?.event == "第一行 第二行 结束")

        log.append(String(repeating: "a", count: 500))
        #expect(log.records.last?.event.count == DiagnosticLog.maximumEventLength)

        log.append(" \n\t ")
        #expect(log.records.count == 2)
    }

    @Test func exportTextIsOrderedAndRedacted() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let log = DiagnosticLog(fileURL: nil, now: { now })
        log.append("发起连接")
        now = now.addingTimeInterval(5)
        log.append("系统 VPN 状态 3")
        let lines = log.exportText.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines.first?.hasSuffix("发起连接") == true)
        #expect(lines.last?.hasSuffix("系统 VPN 状态 3") == true)
    }

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: "Diagnostics.json")
    }
}
