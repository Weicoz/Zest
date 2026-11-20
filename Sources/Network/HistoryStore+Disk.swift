//
//  HistoryStore+Disk.swift
//  Zest
//
//  磁盘读写历史：分钟明细（分钟 × 可执行路径）与小时粒度（供写入提醒）保留 24 小时；
//  按进程日汇总（日期 × 可执行路径，含进程名）永久保留。只有主进程写入，查看器不建表不写。
//

import Foundation
import SQLite3

extension HistoryStore {
    static let diskHourRetention = 24

    func createDiskTables() -> Bool {
        exec("""
            CREATE TABLE IF NOT EXISTS disk_minutes(
                minute INTEGER NOT NULL, path TEXT NOT NULL,
                bytes_read INTEGER NOT NULL, bytes_written INTEGER NOT NULL,
                PRIMARY KEY(minute, path)) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS disk_hours(
                hour INTEGER NOT NULL, path TEXT NOT NULL,
                bytes_read INTEGER NOT NULL, bytes_written INTEGER NOT NULL,
                PRIMARY KEY(hour, path)) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS disk_days(
                day INTEGER NOT NULL, path TEXT NOT NULL, name TEXT NOT NULL,
                bytes_read INTEGER NOT NULL, bytes_written INTEGER NOT NULL,
                PRIMARY KEY(day, path)) WITHOUT ROWID;
            """)
    }

    func clearDisk() {
        guard exec("BEGIN") else { return }
        if !exec("DELETE FROM disk_minutes; DELETE FROM disk_hours; DELETE FROM disk_days") || !exec("COMMIT") { exec("ROLLBACK") }
    }

    func pruneDisk(nowMinute: Int, now: Date, calendar: Calendar) {
        if let s = prepare("DELETE FROM disk_minutes WHERE minute < ?") {
            sqlite3_bind_int64(s, 1, Int64(nowMinute - HistoryStore.retentionMinutes)); sqlite3_step(s); sqlite3_finalize(s)
        }
        if let cut = calendar.date(byAdding: .hour, value: -HistoryStore.diskHourRetention, to: now),
           let s = prepare("DELETE FROM disk_hours WHERE hour < ?") {
            sqlite3_bind_int64(s, 1, Int64(DayRange.hourKey(of: cut, calendar: calendar))); sqlite3_step(s); sqlite3_finalize(s)
        }
    }

    /// 单事务把一批增量累加到分钟、小时、日三张表。任一步骤失败整体回滚并返回 false（调用方保留增量以便重试）。
    @discardableResult
    func addDisk(_ deltas: [DiskDelta], at date: Date, calendar: Calendar = .current) -> Bool {
        guard !deltas.isEmpty else { return true }
        guard exec("BEGIN") else { return false }
        let minute = Int(date.timeIntervalSince1970 / 60)
        let hour = DayRange.hourKey(of: date, calendar: calendar)
        let day = DayRange.key(of: date, calendar: calendar)
        let upsert = " ON CONFLICT DO UPDATE SET bytes_read = bytes_read + excluded.bytes_read, bytes_written = bytes_written + excluded.bytes_written"
        guard let m = prepare("INSERT INTO disk_minutes(minute, path, bytes_read, bytes_written) VALUES(?,?,?,?)" + upsert),
              let h = prepare("INSERT INTO disk_hours(hour, path, bytes_read, bytes_written) VALUES(?,?,?,?)" + upsert),
              let d = prepare("INSERT INTO disk_days(day, path, name, bytes_read, bytes_written) VALUES(?,?,?,?,?)"
                              + upsert + ", name = excluded.name") else { exec("ROLLBACK"); return false }
        var ok = true
        func run(_ s: OpaquePointer, _ key: Int, _ x: DiskDelta, name: Bool = false) {
            sqlite3_reset(s)
            sqlite3_bind_int64(s, 1, Int64(key)); bind(s, 2, x.path)
            var i: Int32 = 3
            if name { bind(s, 3, x.name); i = 4 }
            sqlite3_bind_int64(s, i, Int64(clamping: x.bytesRead)); sqlite3_bind_int64(s, i + 1, Int64(clamping: x.bytesWritten))
            if sqlite3_step(s) != SQLITE_DONE { ok = false }
        }
        for x in deltas { run(m, minute, x); run(h, hour, x); run(d, day, x, name: true) }
        [m, h, d].forEach { sqlite3_finalize($0) }
        if ok, exec("COMMIT") { return true }
        exec("ROLLBACK")
        return false
    }

    /// 范围内按可执行路径汇总的读写（日汇总），按写入降序、路径升序。名称取范围内最近一天的。
    func diskTotals(_ range: DayRange) -> [DiskProcessTotal] {
        guard let s = prepare("""
            SELECT path, name, SUM(bytes_read), SUM(bytes_written), MAX(day) FROM disk_days
            WHERE day >= ? AND day <= ? GROUP BY path ORDER BY SUM(bytes_written) DESC, path
            """) else { return [] }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_int64(s, 1, Int64(range.from)); sqlite3_bind_int64(s, 2, Int64(range.to))
        var r: [DiskProcessTotal] = []
        while sqlite3_step(s) == SQLITE_ROW {
            r.append(DiskProcessTotal(path: text(s, 0) ?? "", name: text(s, 1) ?? "",
                                      bytesRead: UInt64(max(sqlite3_column_int64(s, 2), 0)),
                                      bytesWritten: UInt64(max(sqlite3_column_int64(s, 3), 0))))
        }
        return r
    }

    /// 近 24 小时分钟明细的写入合计（供测试与后续写入提醒核对）。
    func diskMinuteTotal(sinceMinute: Int) -> (read: UInt64, written: UInt64) {
        guard let s = prepare("SELECT COALESCE(SUM(bytes_read),0), COALESCE(SUM(bytes_written),0) FROM disk_minutes WHERE minute >= ?")
        else { return (0, 0) }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_int64(s, 1, Int64(sinceMinute))
        guard sqlite3_step(s) == SQLITE_ROW else { return (0, 0) }
        return (UInt64(max(sqlite3_column_int64(s, 0), 0)), UInt64(max(sqlite3_column_int64(s, 1), 0)))
    }
}
