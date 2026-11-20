//
//  FlowcatImportTests.swift
//  ZestTests
//
//  接缝 B：流量喵 Plus 导入（合成 JSON 夹具，结构照流量喵源码；正确导入、重复不累加、损坏不改已有数据、目录缺失）。
//

import SQLite3
import XCTest
@testable import Zest

final class FlowcatImportTests: XCTestCase {
    private var url: URL!
    private var dir: URL!
    private var store: HistoryStore!

    override func setUpWithError() throws {
        let id = UUID().uuidString
        url = FileManager.default.temporaryDirectory.appendingPathComponent("zest-import-\(id).sqlite")
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("zest-flowcat-\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = try XCTUnwrap(HistoryStore(url: url))
    }

    override func tearDown() {
        store = nil
        ["", "-wal", "-shm"].forEach { try? FileManager.default.removeItem(atPath: url.path + $0) }
        try? FileManager.default.removeItem(at: dir)
    }

    private let ledger = """
    {"version":6,"firstStarted":0,
     "processPaths":{"Safari":"/Applications/Safari.app/Contents/MacOS/Safari","curl":"/usr/bin/curl",
                     "Safari Networking":"/Applications/Safari.app/Contents/XPCServices/N.xpc/Contents/MacOS/N"},
     "days":{"2026-11-10":{"physical":{"received":1000,"sent":200},"monitoredSeconds":5,
                           "processes":{"Safari":{"received":600,"sent":100},"Safari Networking":{"received":50,"sent":5},
                                        "curl":{"received":7,"sent":3}},
                           "hours":{"1":{"received":1,"sent":1}}},
            "2026-11-11":{"physical":{"received":10,"sent":20},"processes":{}},
            "bad-date":{"physical":{"received":1,"sent":1},"processes":{}}}}
    """
    private let connections = """
    {"version":1,"firstStarted":0,"days":{"2026-11-10":{"seconds":3,"routes":{
      "a":{"host":"x.com","rule":"RuleSet","rulePayload":"proxy","chains":["HK-1","Auto"],"bytes":{"download":500,"upload":50},"processes":["Safari"]},
      "b":{"host":"y.com","rule":"RuleSet","rulePayload":"proxy","chains":["HK-1","Auto"],"bytes":{"download":100,"upload":10},"processes":["Safari","curl"]},
      "c":{"host":"z.com","rule":"MATCH","rulePayload":"","chains":["direct"],"bytes":{"download":7,"upload":3},"processes":[]}}}}}
    """
    private let disk = """
    {"version":1,"days":{"2026-11-10":{"processes":{
      "p1":{"name":"git","path":"/usr/bin/git","bytes":{"read":100,"written":40}},
      "p2":{"name":"git","path":"/usr/bin/git","bytes":{"read":1,"written":2}}},"hours":{}}}}
    """

    private func write(_ name: String, _ text: String) throws {
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    private func writeAll() throws {
        try write("ledger.json", ledger); try write("connections.json", connections); try write("disk-ledger.json", disk)
    }
    private func range(_ d: Int) -> DayRange { DayRange(from: d, to: d) }
    private func sql(_ q: String) -> [[String]] {
        var rows: [[String]] = []
        guard let s = store.prepare(q) else { return [["PREPARE FAILED"]] }
        defer { sqlite3_finalize(s) }
        while sqlite3_step(s) == SQLITE_ROW {
            rows.append((0..<sqlite3_column_count(s)).map { String(cString: sqlite3_column_text(s, $0)) })
        }
        return rows
    }

    func testImportsAllCategories() throws {
        try writeAll()
        let r = FlowcatImporter.run(directory: dir, store: store)
        XCTAssertNil(r.failure)
        XCTAssertEqual(r.days, [.physical: 2, .apps: 2, .links: 1, .disk: 1])
        XCTAssertEqual(r.skipped.filter { $0.reason == .badDate }.map(\.day), ["bad-date", "bad-date"])

        let p = store.physicalTotals(range(20261110))
        XCTAssertEqual(p.bytesIn, 1000); XCTAssertEqual(p.bytesOut, 200)

        // Safari 与其 XPC 服务合并到 .app 键；curl 用进程名。
        let apps = Dictionary(uniqueKeysWithValues: store.appTotals(range(20261110)).map { ($0.key, $0) })
        XCTAssertEqual(apps["/Applications/Safari.app"]?.bytesIn, 650)
        XCTAssertEqual(apps["/Applications/Safari.app"]?.bytesOut, 105)
        XCTAssertEqual(apps["/Applications/Safari.app"]?.kind, .app)
        XCTAssertEqual(apps["curl"]?.bytesIn, 7)

        let links = store.linkRows(range(20261110))
        XCTAssertEqual(links.count, 2)
        let proxy = try XCTUnwrap(links.first { $0.rule == "RuleSet: proxy" })
        XCTAssertEqual(proxy.exit, "HK-1"); XCTAssertEqual(proxy.app, "Safari")
        XCTAssertEqual(proxy.traffic, LedgerTraffic(down: 600, up: 60))
        let direct = try XCTUnwrap(links.first { $0.rule == "MATCH" })
        XCTAssertEqual(direct.app, ""); XCTAssertEqual(direct.exit, "DIRECT")

        let d = try XCTUnwrap(store.diskTotals(range(20261110)).first)
        XCTAssertEqual(d.path, "/usr/bin/git"); XCTAssertEqual(d.bytesRead, 101); XCTAssertEqual(d.bytesWritten, 42)
    }

    func testBundleNameIsDisplayNameAndEdgeRecordsSkipped() throws {
        try write("ledger.json", """
        {"processPaths":{"Zeta":"/Applications/Safari.app/Contents/MacOS/Zeta","Alpha":"/Applications/Safari.app/Contents/MacOS/Alpha"},
         "days":{"2026-11-10":{"processes":{"Zeta":{"received":1,"sent":1},"Alpha":{"received":2,"sent":2}}},
                 "2026-02-30":{"physical":{"received":1,"sent":1},"processes":{}}}}
        """)
        try write("disk-ledger.json", #"{"days":{"2026-11-10":{"processes":{"a":{"name":"x","path":"","bytes":{"read":5,"written":5}},"b":{"name":"git","path":"/usr/bin/git","bytes":{"read":1,"written":1}}}}}}"#)
        store.addMinute(Int(Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12))!.timeIntervalSince1970 / 60),
                        traffic: [:], meta: [:], physical: InterfaceCounters(bytesIn: 77, bytesOut: 1))
        let r = FlowcatImporter.run(directory: dir, store: store)
        XCTAssertEqual(store.appMeta()["/Applications/Safari.app"]?.name, "Safari")
        XCTAssertEqual(store.appTotals(range(20261110)).first?.bytesIn, 3)
        XCTAssertEqual(store.physicalTotals(range(20261110)).bytesIn, 77)   // 缺 physical：不删不写
        XCTAssertTrue(r.skipped.contains(.init(category: .physical, day: "2026-11-10", reason: .missingField)))
        XCTAssertTrue(r.skipped.contains(.init(category: .physical, day: "2026-02-30", reason: .badDate)))
        XCTAssertTrue(r.skipped.contains(.init(category: .disk, day: "2026-11-10", reason: .emptyPath)))
        XCTAssertEqual(store.diskTotals(range(20261110)).map(\.path), ["/usr/bin/git"])
    }

    func testRepeatedImportOverwritesAndKeepsOtherDays() throws {
        try writeAll()
        let day9 = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 12))!
        store.addMinute(Int(day9.timeIntervalSince1970 / 60), traffic: [:], meta: [:], physical: InterfaceCounters(bytesIn: 5, bytesOut: 6))
        // 同日已有 Zest 自己的数据：被覆盖，不累加。
        let day10 = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12))!
        store.addMinute(Int(day10.timeIntervalSince1970 / 60), traffic: [:], meta: [:], physical: InterfaceCounters(bytesIn: 9999, bytesOut: 9999))
        _ = FlowcatImporter.run(directory: dir, store: store)
        _ = FlowcatImporter.run(directory: dir, store: store)
        XCTAssertEqual(store.physicalTotals(range(20261110)).bytesIn, 1000)
        XCTAssertEqual(store.physicalTotals(range(20261109)).bytesIn, 5)
        XCTAssertEqual(store.appTotals(range(20261110)).first { $0.key == "curl" }?.bytesIn, 7)
        XCTAssertEqual(store.linkRows(range(20261110)).count, 2)
        XCTAssertEqual(store.diskTotals(range(20261110)).first?.bytesRead, 101)
    }

    func testCorruptFileChangesNothing() throws {
        try writeAll()
        _ = FlowcatImporter.run(directory: dir, store: store)
        // 第二次：ledger 合法但改了数值，disk 损坏 → 整体不变。
        try write("ledger.json", ledger.replacingOccurrences(of: "1000", with: "1"))
        try write("disk-ledger.json", "{not json")
        let r = FlowcatImporter.run(directory: dir, store: store)
        XCTAssertEqual(r.failure, .fileCorrupt("disk-ledger.json"))
        XCTAssertTrue(r.days.isEmpty)
        XCTAssertEqual(store.physicalTotals(range(20261110)).bytesIn, 1000)
        XCTAssertEqual(store.diskTotals(range(20261110)).first?.bytesRead, 101)
    }

    func testWriteFailureRollsBackEverything() throws {
        try writeAll()
        store.exec("DROP TABLE disk_days")   // 最后写入的类别失败
        let r = FlowcatImporter.run(directory: dir, store: store)
        XCTAssertEqual(r.failure, .writeFailed)
        XCTAssertEqual(store.physicalTotals(range(20261110)).bytesIn, 0)
        XCTAssertTrue(store.appTotals(range(20261110)).isEmpty)
        XCTAssertTrue(store.linkRows(range(20261110)).isEmpty)
    }

    func testMissingDirectoryAndMissingFile() throws {
        let none = dir.appendingPathComponent("nope")
        XCTAssertEqual(FlowcatImporter.run(directory: none, store: store).failure, .directoryMissing)
        try write("ledger.json", ledger)
        let r = FlowcatImporter.run(directory: dir, store: store)
        XCTAssertNil(r.failure)
        XCTAssertEqual(r.days, [.physical: 2, .apps: 2])
        XCTAssertEqual(Set(r.skipped.filter { $0.reason == .fileMissing }.map(\.category)), [.links, .disk])
    }
}
