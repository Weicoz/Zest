//
//  DailyTotalsTests.swift
//  ZestTests
//
//  接缝 B：日汇总与整机总量范围查询（临时库，注入时间与日历）。
//

import SQLite3
import XCTest
@testable import Zest

final class DailyTotalsTests: XCTestCase {
    private var url: URL!
    private var cal: Calendar!

    override func setUp() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("zest-daily-\(UUID().uuidString).sqlite")
        cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    }

    override func tearDown() {
        ["", "-wal", "-shm"].forEach { try? FileManager.default.removeItem(atPath: url.path + $0) }
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func minute(_ d: Date) -> Int { Int(d.timeIntervalSince1970 / 60) }

    private func add(_ store: HistoryStore, _ d: Date, _ bytes: UInt64) {
        store.addMinute(minute(d), traffic: [:], meta: [:], physical: InterfaceCounters(bytesIn: bytes, bytesOut: bytes / 10), calendar: cal)
    }

    private func total(_ store: HistoryStore, _ r: TotalsRange, now: Date) -> UInt64 {
        store.physicalTotals(r.dayRange(now: now, calendar: cal)).bytesIn
    }

    func testRangesAcrossMonthBoundary() throws {
        let store = try XCTUnwrap(HistoryStore(url: url))
        add(store, date(2026, 10, 31, 23, 59), 1)      // 上月最后一分钟
        add(store, date(2026, 11, 1, 0, 0), 10)        // 月初 0 点整
        add(store, date(2026, 11, 3, 8), 100)
        add(store, date(2026, 11, 7, 23, 59), 1000)
        let now = date(2026, 11, 7, 15)
        XCTAssertEqual(total(store, .today, now: now), 1000)
        XCTAssertEqual(total(store, .yesterday, now: now), 0)
        // 含今天的 7 个自然日：11-01 ... 11-07
        XCTAssertEqual(total(store, .last7Days, now: now), 10 + 100 + 1000)
        XCTAssertEqual(total(store, .thisMonth, now: now), 1110)
        // 月初当天：昨日在上月，7 天跨月，本月只含当天
        let first = date(2026, 11, 1, 9)
        XCTAssertEqual(total(store, .yesterday, now: first), 1)
        XCTAssertEqual(total(store, .last7Days, now: first), 11)
        XCTAssertEqual(total(store, .thisMonth, now: first), 10)
        XCTAssertEqual(store.physicalTotals(TotalsRange.thisMonth.dayRange(now: now, calendar: cal)).bytesOut, 111)
    }

    func testSurvivesReopenAndMinutePruneAndClear() throws {
        let now = date(2026, 11, 7, 13)
        do {
            let store = try XCTUnwrap(HistoryStore(url: url))
            let m = minute(date(2026, 11, 6, 12))   // 昨天，远超 24 小时
            store.addMinute(m, traffic: ["A": TrafficPoint(bytesIn: 5, bytesOut: 0)], meta: [:],
                            physical: InterfaceCounters(bytesIn: 50, bytesOut: 0), calendar: cal)
            store.addMinute(m, traffic: [:], meta: [:], physical: InterfaceCounters(bytesIn: 7, bytesOut: 0), calendar: cal)
        }
        let store = try XCTUnwrap(HistoryStore(url: url))
        store.prune(nowMinute: minute(now), now: now)
        XCTAssertTrue(store.appTotals(sinceMinute: 0).isEmpty)        // 分钟明细已清理
        XCTAssertEqual(total(store, .yesterday, now: now), 57)       // 日汇总仍在且累加
        store.clearAll()
        XCTAssertEqual(total(store, .yesterday, now: now), 0)
    }

    func testUpgradeFromOldSchemaKeepsMinutes() throws {
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &raw), SQLITE_OK)
        let oldSQL = """
            CREATE TABLE traffic(minute INTEGER NOT NULL, app_key TEXT NOT NULL, bytes_in INTEGER NOT NULL,
                bytes_out INTEGER NOT NULL, PRIMARY KEY(minute, app_key)) WITHOUT ROWID;
            CREATE TABLE apps(app_key TEXT PRIMARY KEY, name TEXT NOT NULL, bundle TEXT, kind INTEGER NOT NULL);
            CREATE TABLE alerts(id TEXT PRIMARY KEY, ts REAL NOT NULL, kind TEXT NOT NULL, app_key TEXT, app_name TEXT,
                detail TEXT NOT NULL, dedup TEXT NOT NULL);
            INSERT INTO traffic VALUES(500, 'A', 42, 3);
            INSERT INTO apps VALUES('A', 'Alpha', NULL, 0);
            """
        XCTAssertEqual(sqlite3_exec(raw, oldSQL, nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)

        let store = try XCTUnwrap(HistoryStore(url: url))
        XCTAssertEqual(store.appTotals(sinceMinute: 0).first?.bytesIn, 42)
        XCTAssertEqual(store.physicalTotals(DayRange(from: 0, to: 99_999_999)).bytesIn, 0)
        add(store, date(2026, 11, 7), 9)
        XCTAssertEqual(total(store, .today, now: date(2026, 11, 7, 20)), 9)
        XCTAssertEqual(store.appTotals(sinceMinute: 0).first?.bytesIn, 42)
    }

    func testFailedWriteRollsBackMinuteAndDailyTotals() throws {
        let store = try XCTUnwrap(HistoryStore(url: url))
        // 另一连接装一个让日汇总插入失败的触发器，模拟写库中途失败。
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &raw), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw, "CREATE TRIGGER fail BEFORE INSERT ON daily_physical BEGIN SELECT RAISE(ABORT,'x'); END;",
                                    nil, nil, nil), SQLITE_OK)
        let d = date(2026, 11, 7, 10)
        let ok = store.addMinute(minute(d), traffic: ["A": TrafficPoint(bytesIn: 5, bytesOut: 1)], meta: [:],
                                 physical: InterfaceCounters(bytesIn: 9, bytesOut: 1), calendar: cal)
        XCTAssertFalse(ok)
        XCTAssertTrue(store.appTotals(sinceMinute: 0).isEmpty)
        XCTAssertEqual(total(store, .today, now: d), 0)
        // 故障消除后重试成功，且只计一次。
        XCTAssertEqual(sqlite3_exec(raw, "DROP TRIGGER fail", nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)
        XCTAssertTrue(store.addMinute(minute(d), traffic: ["A": TrafficPoint(bytesIn: 5, bytesOut: 1)], meta: [:],
                                      physical: InterfaceCounters(bytesIn: 9, bytesOut: 1), calendar: cal))
        XCTAssertEqual(store.appTotals(sinceMinute: 0).first?.bytesIn, 5)
        XCTAssertEqual(total(store, .today, now: d), 9)
    }

    func testAccumulatorRestoreAndDiscard() {
        var acc = PhysicalAccumulator()
        acc.ingest([1: InterfaceCounters(bytesIn: 0, bytesOut: 0)])
        acc.ingest([1: InterfaceCounters(bytesIn: 10, bytesOut: 2)])
        let d = acc.drain()
        acc.restore(d)
        XCTAssertEqual(acc.pending, InterfaceCounters(bytesIn: 10, bytesOut: 2))
        acc.discardPending()
        XCTAssertEqual(acc.pending, InterfaceCounters(bytesIn: 0, bytesOut: 0))
    }

    func testAccumulatorBaselineWrapAndRestart() {
        func c(_ i: UInt64, _ o: UInt64) -> [UInt16: InterfaceCounters] { [1: InterfaceCounters(bytesIn: i, bytesOut: o)] }
        var acc = PhysicalAccumulator()
        acc.ingest(c(1_000, 100))                       // 首次只作基线，不计入
        XCTAssertEqual(acc.drain(), InterfaceCounters(bytesIn: 0, bytesOut: 0))
        acc.ingest(c(1_500, 150))
        acc.ingest(c(20, 5))                            // 计数变小（重置）按 0 起算
        acc.ingest(c(120, 25))                          // 之后从新基线继续
        XCTAssertEqual(acc.drain(), InterfaceCounters(bytesIn: 600, bytesOut: 70))
        XCTAssertEqual(acc.drain(), InterfaceCounters(bytesIn: 0, bytesOut: 0))   // 已取出不重复
        var restarted = PhysicalAccumulator()           // 重启：新累加器首次采样只作基线
        restarted.ingest(c(9_999_999, 9_999_999))
        XCTAssertEqual(restarted.pending, InterfaceCounters(bytesIn: 0, bytesOut: 0))
    }
}

// 应用日汇总（票 03）
extension DailyTotalsTests {
    private func appTotals(_ store: HistoryStore, _ r: TotalsRange, now: Date) -> [String: UInt64] {
        Dictionary(uniqueKeysWithValues: store.appTotals(r.dayRange(now: now, calendar: cal)).map { ($0.key, $0.total) })
    }

    private func addApp(_ store: HistoryStore, _ d: Date, _ key: String, _ bytes: Double) {
        store.addMinute(minute(d), traffic: [key: TrafficPoint(bytesIn: bytes, bytesOut: 1)],
                        meta: [key: AppMeta(key: key, name: key, bundlePath: nil, kind: .app)], calendar: cal)
    }

    func testAppRangesAcrossMonthBoundaryRankedAndSeparateFromPhysical() throws {
        let store = try XCTUnwrap(HistoryStore(url: url))
        addApp(store, date(2026, 10, 31, 23, 59), "A", 100)
        addApp(store, date(2026, 11, 1, 0, 0), "A", 10)
        addApp(store, date(2026, 11, 3, 8), "B", 500)
        addApp(store, date(2026, 11, 7, 9), "A", 1000)
        add(store, date(2026, 11, 7, 9), 7)             // 整机总量与应用互不校正
        let now = date(2026, 11, 7, 15)
        XCTAssertEqual(appTotals(store, .today, now: now), ["A": 1001])
        XCTAssertTrue(appTotals(store, .yesterday, now: now).isEmpty)
        XCTAssertEqual(appTotals(store, .last7Days, now: now), ["A": 1001 + 11, "B": 501])
        XCTAssertEqual(appTotals(store, .thisMonth, now: now), ["A": 1012, "B": 501])
        XCTAssertEqual(store.appTotals(TotalsRange.thisMonth.dayRange(now: now, calendar: cal)).map(\.key), ["A", "B"])
        XCTAssertEqual(appTotals(store, .yesterday, now: date(2026, 11, 1, 9)), ["A": 101])
        XCTAssertEqual(total(store, .today, now: now), 7)
        XCTAssertEqual(store.appTotals(TotalsRange.today.dayRange(now: now, calendar: cal)).first?.name, "A")
    }

    func testAppDailySurvivesMinutePruneAndClear() throws {
        let now = date(2026, 11, 7, 13)
        let store = try XCTUnwrap(HistoryStore(url: url))
        addApp(store, date(2026, 11, 6, 12), "A", 5)
        store.prune(nowMinute: minute(now), now: now)
        XCTAssertTrue(store.appTotals(sinceMinute: 0).isEmpty)
        XCTAssertEqual(appTotals(store, .yesterday, now: now), ["A": 6])
        XCTAssertEqual(store.appTotals(TotalsRange.yesterday.dayRange(now: now, calendar: cal)).first?.name, "A")
        store.clearAll()
        XCTAssertTrue(appTotals(store, .yesterday, now: now).isEmpty)
    }

    func testFailedWriteRollsBackAppDaily() throws {
        let store = try XCTUnwrap(HistoryStore(url: url))
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &raw), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw, "CREATE TRIGGER failapp BEFORE INSERT ON daily_apps BEGIN SELECT RAISE(ABORT,'x'); END;",
                                    nil, nil, nil), SQLITE_OK)
        let d = date(2026, 11, 7, 10)
        let t = ["A": TrafficPoint(bytesIn: 5, bytesOut: 1)]
        XCTAssertFalse(store.addMinute(minute(d), traffic: t, meta: [:], physical: InterfaceCounters(bytesIn: 9, bytesOut: 1), calendar: cal))
        XCTAssertTrue(store.appTotals(sinceMinute: 0).isEmpty)
        XCTAssertEqual(total(store, .today, now: d), 0)
        XCTAssertEqual(sqlite3_exec(raw, "DROP TRIGGER failapp", nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)
        XCTAssertTrue(store.addMinute(minute(d), traffic: t, meta: [:], physical: InterfaceCounters(bytesIn: 9, bytesOut: 1), calendar: cal))
        XCTAssertEqual(appTotals(store, .today, now: d), ["A": 6])
        XCTAssertEqual(total(store, .today, now: d), 9)
    }

    func testUpgradeBackfillsAppDailyOnceFromMinutes() throws {
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &raw), SQLITE_OK)
        let m1 = minute(date(2026, 11, 7, 9)), m2 = minute(date(2026, 11, 7, 10)), m0 = minute(date(2026, 11, 6, 23, 59))
        let oldSQL = """
            CREATE TABLE traffic(minute INTEGER NOT NULL, app_key TEXT NOT NULL, bytes_in INTEGER NOT NULL,
                bytes_out INTEGER NOT NULL, PRIMARY KEY(minute, app_key)) WITHOUT ROWID;
            CREATE TABLE apps(app_key TEXT PRIMARY KEY, name TEXT NOT NULL, bundle TEXT, kind INTEGER NOT NULL);
            INSERT INTO traffic VALUES(\(m1), 'A', 40, 2);
            INSERT INTO traffic VALUES(\(m2), 'A', 2, 1);
            INSERT INTO traffic VALUES(\(m0), 'A', 100, 0);
            INSERT INTO apps VALUES('A', 'Alpha', NULL, 0);
            """
        XCTAssertEqual(sqlite3_exec(raw, oldSQL, nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)
        let now = date(2026, 11, 7, 20)
        // 查看器先打开：不得建表也不回填，主进程之后仍能回填。
        _ = try XCTUnwrap(HistoryStore(url: url, migrate: false, calendar: cal))
        do {
            let store = try XCTUnwrap(HistoryStore(url: url, calendar: cal))
            XCTAssertEqual(appTotals(store, .today, now: now), ["A": 45])
            XCTAssertEqual(appTotals(store, .yesterday, now: now), ["A": 100])
        }
        let again = try XCTUnwrap(HistoryStore(url: url, calendar: cal))   // 重开不重复累加
        XCTAssertEqual(appTotals(again, .today, now: now), ["A": 45])
        XCTAssertEqual(again.appTotals(TotalsRange.today.dayRange(now: now, calendar: cal)).first?.name, "Alpha")
    }
}
