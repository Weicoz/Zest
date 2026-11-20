//
//  LinkHistoryTests.swift
//  ZestTests
//
//  接缝 B：链路账本的历史存储（临时库，注入时间与日历）。
//

import SQLite3
import XCTest
@testable import Zest

final class LinkHistoryTests: XCTestCase {
    private var url: URL!
    private var cal: Calendar!

    override func setUp() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("zest-links-\(UUID().uuidString).sqlite")
        cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    }

    override func tearDown() {
        ["", "-wal", "-shm"].forEach { try? FileManager.default.removeItem(atPath: url.path + $0) }
    }

    private func date(_ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: 2026, month: m, day: d, hour: h))!
    }

    /// 在 at 所在日、小时记一条增量。
    private func delta(_ at: Date, rule: String = "R1", exit: String = "node-a", app: String = "app1", host: String = "h.example.test",
                       down: Int64, up: Int64 = 0, unattributed: Int64 = 0) -> LedgerDelta {
        let day = DayRange.key(of: at, calendar: cal), hour = DayRange.hourKey(of: at, calendar: cal)
        var d = LedgerDelta()
        d.routes[.init(day: day, rule: rule, exit: exit, app: app)] = LedgerTraffic(down: down, up: up)
        d.domains[.init(day: day, host: host, rule: rule, exit: exit, app: app)] = LedgerTraffic(down: down, up: up)
        d.hours[.init(hour: hour, rule: rule, exit: exit, app: app)] = LedgerTraffic(down: down, up: up)
        if unattributed > 0 {
            d.unattributed[day] = LedgerTraffic(down: unattributed, up: 0)
            d.unattributedHours[hour] = LedgerTraffic(down: unattributed, up: 0)
        }
        return d
    }

    func testRangeQueriesAndUnattributedRow() throws {
        let store = try XCTUnwrap(HistoryStore(url: url))
        XCTAssertTrue(store.addLinks(delta(date(10, 31, 23), down: 1)))
        XCTAssertTrue(store.addLinks(delta(date(11, 6, 9), rule: "R2", down: 10, unattributed: 3)))
        XCTAssertTrue(store.addLinks(delta(date(11, 7, 8), down: 100, up: 5, unattributed: 7)))
        XCTAssertTrue(store.addLinks(delta(date(11, 7, 9), down: 1000)))   // 同日同键累加
        let now = date(11, 7, 15)
        let today = store.linkSnapshot(.today, rule: nil, now: now, calendar: cal)
        XCTAssertEqual(today.rules, [LinkGroup(name: "R1", traffic: LedgerTraffic(down: 1100, up: 5))])
        XCTAssertEqual(today.unattributed, LedgerTraffic(down: 7, up: 0))
        XCTAssertEqual(today.total, LedgerTraffic(down: 1107, up: 5))
        let yesterday = store.linkSnapshot(.yesterday, rule: nil, now: now, calendar: cal)
        XCTAssertEqual(yesterday.rules.map(\.name), ["R2"])
        XCTAssertEqual(yesterday.unattributed.down, 3)
        let month = store.linkSnapshot(.thisMonth, rule: nil, now: now, calendar: cal)
        XCTAssertEqual(month.rules.map(\.name), ["R1", "R2"])   // 10-31 不在本月
        XCTAssertEqual(month.unattributed.down, 10)
        XCTAssertEqual(month.daily.count, 7)
        XCTAssertEqual(month.daily.last?.traffic.down, 1107)   // 当日柱含未归属
        // 未归属不混进规则、出口、应用列表。
        XCTAssertFalse(month.rules.contains { $0.name == LinkKey.unattributed })
        XCTAssertEqual(month.exits.map(\.name), ["node-a"])
    }

    func testRuleSelectionScopesEverything() throws {
        let store = try XCTUnwrap(HistoryStore(url: url))
        let now = date(11, 7, 15)
        store.addLinks(delta(date(11, 7, 8), rule: "R1", exit: "e1", app: "a1", host: "x.test", down: 100, unattributed: 9))
        store.addLinks(delta(date(11, 7, 9), rule: "R2", exit: "e2", app: "a2", host: "y.test", down: 40))
        let s = store.linkSnapshot(.today, rule: "R2", now: now, calendar: cal)
        XCTAssertEqual(s.rules.map(\.name).sorted(), ["R1", "R2"])   // 规则列表保留，便于切换
        XCTAssertEqual(s.exits.map(\.name), ["e2"])
        XCTAssertEqual(s.apps.map(\.name), ["a2"])
        XCTAssertEqual(s.domains.map(\.name), ["y.test"])
        XCTAssertEqual(s.total, LedgerTraffic(down: 40, up: 0))
        XCTAssertEqual(s.unattributed, LedgerTraffic())
        XCTAssertEqual(s.hourly.reduce(0) { $0 + $1.traffic.down }, 40)
        XCTAssertEqual(s.daily.reduce(0) { $0 + $1.traffic.down }, 40)
    }

    func testHourlyBarsCoverLast24HoursAndPrune() throws {
        let store = try XCTUnwrap(HistoryStore(url: url))
        let now = date(11, 7, 15)
        store.addLinks(delta(date(11, 6, 14), down: 1))    // 25 小时前：不在柱图内
        store.addLinks(delta(date(11, 6, 16), down: 10))   // 23 小时前：最早一根
        store.addLinks(delta(date(11, 7, 15), down: 100))  // 当前小时
        var bars = store.linkSnapshot(.today, rule: nil, now: now, calendar: cal).hourly
        XCTAssertEqual(bars.count, 24)
        XCTAssertEqual(bars.first?.traffic.down, 10)
        XCTAssertEqual(bars.last?.traffic.down, 100)
        XCTAssertEqual(bars.reduce(0) { $0 + $1.traffic.down }, 110)
        // 24 小时前的小时记录被清理，日汇总不受影响。
        store.prune(nowMinute: Int(now.timeIntervalSince1970 / 60), now: now, calendar: cal)
        bars = store.linkSnapshot(.today, rule: nil, now: date(11, 6, 15), calendar: cal).hourly   // 回看被清理的那个小时
        XCTAssertEqual(bars.reduce(0) { $0 + $1.traffic.down }, 0)
        XCTAssertEqual(store.linkSnapshot(.last7Days, rule: nil, now: now, calendar: cal).total.down, 111)
    }

    func testDomainRecordsPrunedAt30DaysButRouteSummaryKept() throws {
        let store = try XCTUnwrap(HistoryStore(url: url))
        let now = date(11, 20, 12)
        store.addLinks(delta(date(10, 20, 9), host: "old.test", down: 5))    // 31 天前
        store.addLinks(delta(date(10, 21, 9), host: "edge.test", down: 6))   // 30 天前，保留
        store.addLinks(delta(date(11, 20, 9), host: "new.test", down: 7))
        store.prune(nowMinute: Int(now.timeIntervalSince1970 / 60), now: now, calendar: cal)
        let wide = DayRange(from: 20261001, to: 20261120)
        XCTAssertEqual(store.linkDomains(wide, rule: nil).map(\.name).sorted(), ["edge.test", "new.test"])
        let routes = store.linkRows(wide).reduce(Int64(0)) { $0 + $1.traffic.down }
        XCTAssertEqual(routes, 18)   // 规则 × 出口 × 应用日汇总永久保留
    }

    func testFailedWriteRollsBackAndRetryCountsOnce() throws {
        let store = try XCTUnwrap(HistoryStore(url: url))
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &raw), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw, "CREATE TRIGGER fail BEFORE INSERT ON link_hours BEGIN SELECT RAISE(ABORT,'x'); END;",
                                    nil, nil, nil), SQLITE_OK)
        let at = date(11, 7, 10)
        let d = delta(at, down: 50, unattributed: 4)
        XCTAssertFalse(store.addLinks(d))
        XCTAssertTrue(store.linkRows(DayRange(from: 20261107, to: 20261107)).isEmpty)   // link_days 与域名一并回滚
        XCTAssertTrue(store.linkDomains(DayRange(from: 20261107, to: 20261107), rule: nil).isEmpty)
        XCTAssertEqual(sqlite3_exec(raw, "DROP TRIGGER fail", nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)
        XCTAssertTrue(store.addLinks(d))
        XCTAssertEqual(store.linkSnapshot(.today, rule: nil, now: at, calendar: cal).total.down, 54)
    }

    func testPendingMergeAndClearAndReopenAndViewerDoesNotCreateTables() throws {
        let at = date(11, 7, 10)
        var merged = delta(at, down: 5)
        merged.merge(delta(at, down: 7))
        do {
            let store = try XCTUnwrap(HistoryStore(url: url))
            XCTAssertTrue(store.addLinks(merged))
        }
        let store = try XCTUnwrap(HistoryStore(url: url, migrate: false))   // 重开后数据仍在
        XCTAssertEqual(store.linkSnapshot(.today, rule: nil, now: at, calendar: cal).total.down, 12)
        let primary = try XCTUnwrap(HistoryStore(url: url))
        primary.clearAll()
        XCTAssertEqual(primary.linkSnapshot(.today, rule: nil, now: at, calendar: cal).total, LedgerTraffic())
    }

    func testViewerNeverPrunes() throws {
        let at = date(11, 7, 10)
        do {
            let primary = try XCTUnwrap(HistoryStore(url: url))
            primary.addLinks(delta(at, down: 5))
            primary.addMinute(Int(at.timeIntervalSince1970 / 60), traffic: ["A": TrafficPoint(bytesIn: 3, bytesOut: 0)], meta: [:], calendar: cal)
        }
        let viewer = try XCTUnwrap(HistoryStore(url: url, migrate: false))
        let later = date(12, 31)   // 远超 24 小时与 30 天
        viewer.prune(nowMinute: Int(later.timeIntervalSince1970 / 60), now: later, calendar: cal)
        XCTAssertEqual(viewer.appTotals(sinceMinute: 0).first?.bytesIn, 3)
        XCTAssertEqual(viewer.linkDomains(DayRange(from: 20261107, to: 20261107), rule: nil).map(\.name), ["h.example.test"])
        XCTAssertEqual(viewer.linkHourlyBars(now: at, rule: nil, calendar: cal).reduce(0) { $0 + $1.traffic.down }, 5)
    }

    func testViewerOnFreshDatabaseHasNoLinkTables() throws {
        let viewer = try XCTUnwrap(HistoryStore(url: url, migrate: false))
        XCTAssertFalse(viewer.addLinks(delta(date(11, 7), down: 1)))   // 查看器不建表，写入失败
        XCTAssertEqual(viewer.linkSnapshot(.today, rule: nil, now: date(11, 7), calendar: cal).total, LedgerTraffic())
    }
}
