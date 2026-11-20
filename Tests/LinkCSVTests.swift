//
//  LinkCSVTests.swift
//  ZestTests
//
//  链路搜索、筛选与 CSV：纯函数加临时库，时间与日历注入。
//

import XCTest
@testable import Zest

final class LinkCSVTests: XCTestCase {
    private func rec(_ day: Int, host: String? = nil, rule: String = "R1", exit: String = "node-a", app: String = "app1",
                     down: Int64 = 1, up: Int64 = 2) -> LinkExportRecord {
        LinkExportRecord(day: day, host: host, rule: rule, exit: exit, app: app, traffic: LedgerTraffic(down: down, up: up))
    }

    private func lines(_ csv: String) -> [String] { csv.components(separatedBy: "\r\n").dropLast() }

    func testFieldEscapesCommaQuoteNewline() {
        XCTAssertEqual(LinkCSV.field("plain"), "plain")
        XCTAssertEqual(LinkCSV.field("a,b"), "\"a,b\"")
        XCTAssertEqual(LinkCSV.field("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(LinkCSV.field("l1\nl2"), "\"l1\nl2\"")
    }

    func testDocumentHeaderAndRowEscaping() {
        let doc = LinkCSV.document(days: [], domains: [rec(20261107, host: "a,b.test", app: "My \"App\"")],
                                   domainCutoffDay: 20261001, filter: LinkFilter(), rule: nil)
        let l = lines(doc)
        XCTAssertEqual(l[0], "日期,小时,域名,地址,端口,应用,规则,规则载荷,策略链,出口,下载字节,上传字节")
        XCTAssertEqual(l[1], "2026-11-07,,\"a,b.test\",,,\"My \"\"App\"\"\",R1,,,node-a,1,2")
    }

    func testOlderThanRetentionHasBlankDomainAndRouteGranularity() {
        let doc = LinkCSV.document(
            days: [rec(20260901, down: 10), rec(20261107, down: 99)],            // 11-07 在保留期内，日汇总行不应出现
            domains: [rec(20261107, host: "x.test", down: 7)],
            domainCutoffDay: 20261008, filter: LinkFilter(), rule: nil)
        let l = lines(doc)
        XCTAssertEqual(l.count, 3)
        XCTAssertEqual(l[1], "2026-09-01,,,,,app1,R1,,,node-a,10,2")
        XCTAssertEqual(l[2], "2026-11-07,,x.test,,,app1,R1,,,node-a,7,2")
    }

    func testFilterAndRuleScopeApplyToCSVAndUnattributedOnlyWhenUnfiltered() {
        let days = [rec(20260901, rule: "R1", exit: "DIRECT"), rec(20260901, rule: "R2", exit: "node-a"),
                    rec(20260901, rule: LinkKey.unattributed, exit: "", app: "")]
        func body(_ f: LinkFilter, rule: String? = nil) -> [String] {
            Array(lines(LinkCSV.document(days: days, domains: [], domainCutoffDay: 20261001, filter: f, rule: rule)).dropFirst())
        }
        XCTAssertEqual(body(LinkFilter()).count, 3)
        XCTAssertTrue(body(LinkFilter()).contains { $0.contains("未归属") })
        XCTAssertEqual(body(LinkFilter(mode: .direct)).count, 1)
        XCTAssertEqual(body(LinkFilter(mode: .proxy)).count, 1)
        XCTAssertEqual(body(LinkFilter(search: "r2")).count, 1)
        XCTAssertEqual(body(LinkFilter(), rule: "R1").count, 1)
    }

    // MARK: 搜索与筛选作用于存储查询

    private var url: URL!
    override func setUp() { url = FileManager.default.temporaryDirectory.appendingPathComponent("zest-csv-\(UUID().uuidString).sqlite") }
    override func tearDown() { ["", "-wal", "-shm"].forEach { try? FileManager.default.removeItem(atPath: url.path + $0) } }

    func testSnapshotFilterScopesListsTotalsAndBars() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let at = cal.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 12))!
        let day = DayRange.key(of: at, calendar: cal), hour = DayRange.hourKey(of: at, calendar: cal)
        var d = LedgerDelta()
        for (rule, exit, host, n) in [("R1", "DIRECT", "Direct.test", Int64(10)), ("R2", "node-a", "Proxy.test", Int64(100))] {
            d.routes[.init(day: day, rule: rule, exit: exit, app: "app1")] = LedgerTraffic(down: n, up: 0)
            d.domains[.init(day: day, host: host, rule: rule, exit: exit, app: "app1")] = LedgerTraffic(down: n, up: 0)
            d.hours[.init(hour: hour, rule: rule, exit: exit, app: "app1")] = LedgerTraffic(down: n, up: 0)
        }
        d.unattributed[day] = LedgerTraffic(down: 5, up: 0)
        let store = try XCTUnwrap(HistoryStore(url: url))
        XCTAssertTrue(store.addLinks(d))
        func snap(_ f: LinkFilter) -> LinkSnapshot { store.linkSnapshot(.today, rule: nil, filter: f, now: at, calendar: cal) }
        XCTAssertEqual(snap(LinkFilter()).total.down, 115)
        let direct = snap(LinkFilter(mode: .direct))
        XCTAssertEqual(direct.total.down, 10)
        XCTAssertEqual(direct.rules.map(\.name), ["R1"])
        XCTAssertEqual(direct.domains.map(\.name), ["Direct.test"])
        XCTAssertEqual(direct.daily.last?.traffic.down, 10)
        XCTAssertEqual(direct.hourly.last?.traffic.down, 10)
        XCTAssertEqual(direct.unattributed, LedgerTraffic())
        let proxy = snap(LinkFilter(mode: .proxy))
        XCTAssertEqual(proxy.total.down, 100)
        let search = snap(LinkFilter(search: "PROXY.TEST"))   // 域名搜索：只缩小域名列表
        XCTAssertEqual(search.domains.map(\.name), ["Proxy.test"])
        XCTAssertEqual(snap(LinkFilter(search: "node-a")).total.down, 100)
        XCTAssertEqual(snap(LinkFilter(search: "APP1")).total.down, 110)
    }
}
