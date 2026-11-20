//
//  DiskLedgerTests.swift
//  ZestTests
//
//  接缝 C：磁盘核心（伪造的按进程快照序列）；接缝 B：磁盘日汇总范围查询、分钟清理、写失败回滚。
//

import SQLite3
import XCTest
@testable import Zest

final class DiskLedgerTests: XCTestCase {
    private func t(_ s: Double) -> Date { Date(timeIntervalSince1970: s) }

    private func snap(_ pid: Int32, _ path: String = "/bin/a", start: Double = 100, read: UInt64 = 0, written: UInt64) -> DiskProcessSnapshot {
        DiskProcessSnapshot(pid: pid, path: path, name: (path as NSString).lastPathComponent, startTime: start,
                            bytesRead: read, bytesWritten: written)
    }

    func testFirstSampleIsBaselineOnly() {
        var acc = DiskAccumulator()
        acc.ingest([snap(1, written: 1_000_000)], at: t(1000))
        XCTAssertTrue(acc.drain().isEmpty)
    }

    func testMergesProcessesByExecutablePath() {
        var acc = DiskAccumulator()
        acc.ingest([snap(1, "/bin/a", written: 10), snap(2, "/bin/a", read: 5, written: 20), snap(3, "/bin/b", written: 1)], at: t(1000))
        acc.ingest([snap(1, "/bin/a", written: 110), snap(2, "/bin/a", read: 9, written: 50), snap(3, "/bin/b", written: 1)], at: t(1010))
        XCTAssertEqual(acc.drain(), [DiskDelta(path: "/bin/a", name: "a", bytesRead: 4, bytesWritten: 130)])
    }

    func testPidReuseCountsNothing() {
        var acc = DiskAccumulator()
        acc.ingest([snap(1, start: 100, written: 5_000_000_000)], at: t(1000))
        // 同一 PID、不同启动时间：新进程，不得用新旧累计值之差，也不得把新进程累计值当增量。
        acc.ingest([snap(1, start: 1005, written: 7_000_000_000)], at: t(1010))
        XCTAssertTrue(acc.drain().isEmpty)
        acc.ingest([snap(1, start: 1005, written: 7_000_000_100)], at: t(1020))
        XCTAssertEqual(acc.drain().first?.bytesWritten, 100)
    }

    func testCounterDecreaseCountsZeroThenResumes() {
        var acc = DiskAccumulator()
        acc.ingest([snap(1, written: 1000)], at: t(1000))
        acc.ingest([snap(1, written: 40)], at: t(1010))
        XCTAssertTrue(acc.drain().isEmpty)
        acc.ingest([snap(1, written: 100)], at: t(1020))
        XCTAssertEqual(acc.drain().first?.bytesWritten, 60)
    }

    func testNewProcessCountedInFullOnlyIfStartedAfterLastSample() {
        var acc = DiskAccumulator()
        acc.ingest([snap(1, written: 0)], at: t(1000))
        acc.ingest([snap(1, written: 0), snap(2, "/bin/new", start: 1005, written: 300), snap(3, "/bin/old", start: 50, written: 9_000)],
                   at: t(1010))
        XCTAssertEqual(acc.drain(), [DiskDelta(path: "/bin/new", name: "new", bytesRead: 0, bytesWritten: 300)])
    }

    func testRestoreAndDiscard() {
        var acc = DiskAccumulator()
        acc.ingest([snap(1, written: 0)], at: t(1000))
        acc.ingest([snap(1, written: 10)], at: t(1010))
        let batch = acc.drain()
        acc.restore(batch)
        acc.ingest([snap(1, written: 15)], at: t(1020))
        XCTAssertEqual(acc.drain().first?.bytesWritten, 15)
        acc.ingest([snap(1, written: 20)], at: t(1030))
        acc.discardPending()
        XCTAssertTrue(acc.drain().isEmpty)
    }

    // MARK: 接缝 B

    private var url: URL!
    private var cal: Calendar!

    override func setUp() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("zest-disk-\(UUID().uuidString).sqlite")
        cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    }

    override func tearDown() {
        ["", "-wal", "-shm"].forEach { try? FileManager.default.removeItem(atPath: url.path + $0) }
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private func delta(_ path: String, _ name: String, read: UInt64 = 0, written: UInt64) -> DiskDelta {
        DiskDelta(path: path, name: name, bytesRead: read, bytesWritten: written)
    }

    private func totals(_ s: HistoryStore, _ r: TotalsRange, now: Date) -> [DiskProcessTotal] {
        s.diskTotals(r.dayRange(now: now, calendar: cal))
    }

    func testRangeQueriesAcrossMonthBoundary() throws {
        let s = try XCTUnwrap(HistoryStore(url: url))
        s.addDisk([delta("/a", "A", written: 1)], at: date(2026, 10, 31, 23), calendar: cal)
        s.addDisk([delta("/a", "A", read: 2, written: 10)], at: date(2026, 11, 1, 0), calendar: cal)
        s.addDisk([delta("/a", "A2", written: 100), delta("/b", "B", written: 5)], at: date(2026, 11, 7, 9), calendar: cal)
        let now = date(2026, 11, 7, 15)
        XCTAssertEqual(totals(s, .today, now: now).map(\.path), ["/a", "/b"])
        XCTAssertEqual(totals(s, .today, now: now).first?.bytesWritten, 100)
        XCTAssertTrue(totals(s, .yesterday, now: now).isEmpty)
        XCTAssertEqual(totals(s, .last7Days, now: now).first?.bytesWritten, 110)
        let month = totals(s, .thisMonth, now: now)
        XCTAssertEqual(month.first?.bytesWritten, 110)
        XCTAssertEqual(month.first?.bytesRead, 2)
        XCTAssertEqual(month.first?.name, "A2")   // 名称取范围内最近一天的
        XCTAssertEqual(month.last?.path, "/b")
    }

    func testDailySurvivesMinutePruneAndReopen() throws {
        var s: HistoryStore? = try XCTUnwrap(HistoryStore(url: url))
        let d = date(2026, 11, 7, 9)
        s?.addDisk([delta("/a", "A", written: 100)], at: d, calendar: cal)
        let minute = Int(d.timeIntervalSince1970 / 60)
        XCTAssertEqual(s?.diskMinuteTotal(sinceMinute: 0).written, 100)
        let later = d.addingTimeInterval(25 * 3600)
        s?.prune(nowMinute: minute + 25 * 60, now: later, calendar: cal)
        XCTAssertEqual(s?.diskMinuteTotal(sinceMinute: 0).written, 0)   // 分钟明细已清
        s = nil
        let reopened = try XCTUnwrap(HistoryStore(url: url))
        XCTAssertEqual(totals(reopened, .last7Days, now: later).first?.bytesWritten, 100)
    }

    func testFailedWriteRollsBackAndRetryCountsOnce() throws {
        let s = try XCTUnwrap(HistoryStore(url: url))
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &raw), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw, "CREATE TRIGGER faildisk BEFORE INSERT ON disk_days BEGIN SELECT RAISE(ABORT,'x'); END;",
                                    nil, nil, nil), SQLITE_OK)
        let d = date(2026, 11, 7, 10)
        XCTAssertFalse(s.addDisk([delta("/a", "A", written: 7)], at: d, calendar: cal))
        XCTAssertEqual(s.diskMinuteTotal(sinceMinute: 0).written, 0)   // 分钟表一并回滚
        XCTAssertEqual(sqlite3_exec(raw, "DROP TRIGGER faildisk", nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)
        XCTAssertTrue(s.addDisk([delta("/a", "A", written: 7)], at: d, calendar: cal))
        XCTAssertEqual(totals(s, .today, now: d).first?.bytesWritten, 7)
        XCTAssertEqual(s.diskMinuteTotal(sinceMinute: 0).written, 7)
    }

    func testClearAllRemovesDiskTables() throws {
        let s = try XCTUnwrap(HistoryStore(url: url))
        let d = date(2026, 11, 7, 10)
        s.addDisk([delta("/a", "A", written: 7)], at: d, calendar: cal)
        s.clearAll()
        XCTAssertTrue(totals(s, .today, now: d).isEmpty)
        XCTAssertEqual(s.diskMinuteTotal(sinceMinute: 0).written, 0)
    }
}
