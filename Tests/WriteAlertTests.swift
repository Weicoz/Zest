//
//  WriteAlertTests.swift
//  ZestTests
//
//  接缝 C：写入提醒（每小时与每天阈值、同时段去重、阈值 0、跨重启不重复、随清除历史清除）。时间与日历注入。
//

import XCTest
@testable import Zest

final class WriteAlertTests: XCTestCase {
    private var url: URL!
    private var cal: Calendar!
    private let gb: UInt64 = 1 << 30

    override func setUp() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("zest-alert-\(UUID().uuidString).sqlite")
        cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    }

    override func tearDown() {
        ["", "-wal", "-shm"].forEach { try? FileManager.default.removeItem(atPath: url.path + $0) }
    }

    private func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m))!
    }

    private func write(_ s: HistoryStore, _ path: String, _ bytes: UInt64, _ date: Date) {
        s.addDisk([DiskDelta(path: path, name: (path as NSString).lastPathComponent, bytesRead: 0, bytesWritten: bytes)], at: date, calendar: cal)
    }

    private func check(_ s: HistoryStore, hour: UInt64 = 2, day: UInt64 = 10, now: Date) -> [WriteAlertRecord] {
        s.checkWriteAlerts(hourBytes: hour * gb, dayBytes: day * gb, now: now, calendar: cal)
    }

    func testHourlyThresholdIsStrictAndPerHour() throws {
        let s = try XCTUnwrap(HistoryStore(url: url, calendar: cal))
        write(s, "/bin/a", 2 * gb, at(5, 9, 10))
        XCTAssertTrue(check(s, now: at(5, 9, 20)).isEmpty)   // 恰好等于阈值不触发
        write(s, "/bin/a", 1, at(5, 9, 30))
        let r = check(s, now: at(5, 9, 31))
        XCTAssertEqual(r.map(\.tier), [.hour])
        XCTAssertEqual(r.first?.path, "/bin/a")
        XCTAssertEqual(r.first?.name, "a")
        XCTAssertEqual(r.first?.bytesWritten, 2 * gb + 1)
        // 下一个整点的写入不与上一小时合计
        write(s, "/bin/a", gb, at(5, 10, 5))
        XCTAssertTrue(check(s, now: at(5, 10, 6)).isEmpty)
    }

    func testDailyThresholdSumsAcrossHours() throws {
        let s = try XCTUnwrap(HistoryStore(url: url, calendar: cal))
        for h in 0..<6 { write(s, "/bin/a", 2 * gb, at(5, h)) }   // 每小时 2 GB，不超小时档；全天 12 GB
        let r = check(s, now: at(5, 6))
        XCTAssertEqual(r.map(\.tier), [.day])
        XCTAssertEqual(r.first?.bytesWritten, 12 * gb)
    }

    func testBothTiersOncePerPeriod() throws {
        let s = try XCTUnwrap(HistoryStore(url: url, calendar: cal))
        write(s, "/bin/a", 11 * gb, at(5, 9))
        XCTAssertEqual(Set(check(s, now: at(5, 9, 1)).map(\.tier)), [.hour, .day])
        write(s, "/bin/a", gb, at(5, 9, 30))
        XCTAssertTrue(check(s, now: at(5, 9, 31)).isEmpty)   // 同时段不重复
        write(s, "/bin/a", 3 * gb, at(5, 10))
        XCTAssertEqual(check(s, now: at(5, 10, 1)).map(\.tier), [.hour])   // 新小时可再提醒，当天日档已提醒
        write(s, "/bin/b", 11 * gb, at(5, 10))
        XCTAssertEqual(check(s, now: at(5, 10, 2)).filter { $0.path == "/bin/b" }.count, 2)   // 另一程序独立
    }

    func testZeroDisablesTier() throws {
        let s = try XCTUnwrap(HistoryStore(url: url, calendar: cal))
        write(s, "/bin/a", 11 * gb, at(5, 9))
        XCTAssertEqual(check(s, hour: 0, now: at(5, 9, 1)).map(\.tier), [.day])
        XCTAssertEqual(check(s, hour: 0, day: 0, now: at(5, 9, 2)).count, 0)
        XCTAssertEqual(check(s, day: 0, now: at(5, 9, 3)).map(\.tier), [.hour])   // 先前关闭时未记录，打开后仍可触发
    }

    func testNoRepeatAfterReopen() throws {
        var s: HistoryStore? = try XCTUnwrap(HistoryStore(url: url, calendar: cal))
        write(s!, "/bin/a", 11 * gb, at(5, 9))
        XCTAssertEqual(check(s!, now: at(5, 9, 1)).count, 2)
        s = nil
        let reopened = try XCTUnwrap(HistoryStore(url: url, calendar: cal))
        XCTAssertTrue(check(reopened, now: at(5, 9, 40)).isEmpty)
        XCTAssertEqual(reopened.recentWriteAlerts().count, 2)
    }

    func testClearHistoryRemovesAlertRecords() throws {
        let s = try XCTUnwrap(HistoryStore(url: url, calendar: cal))
        write(s, "/bin/a", 11 * gb, at(5, 9))
        XCTAssertEqual(check(s, now: at(5, 9, 1)).count, 2)
        s.clearAll()
        XCTAssertTrue(s.recentWriteAlerts().isEmpty)
    }
}
