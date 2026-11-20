//
//  HistoryStore+WriteAlerts.swift
//  Zest
//
//  写入提醒：某可执行路径在本地整点小时或本地日内写入超过阈值时触发，每档每程序每时段只一次。
//  判断数据来自 disk_hours 与 disk_days；已触发记录存 write_alerts（时段键 × 档位 × 路径唯一），重启后不重复。
//  只有主进程写入；查看器只读 recentWriteAlerts。
//

import Foundation
import SQLite3

enum WriteAlertTier: Int, Equatable {
    case hour = 0, day = 1
}

struct WriteAlertRecord: Identifiable, Equatable {
    var date: Date
    var tier: WriteAlertTier
    var path: String
    var name: String
    var bytesWritten: UInt64
    var id: String { "\(tier.rawValue)|\(date.timeIntervalSince1970)|\(path)" }
}

extension HistoryStore {
    static let writeAlertRetentionDays = 30

    func createWriteAlertTable() -> Bool {
        exec("""
            CREATE TABLE IF NOT EXISTS write_alerts(
                period INTEGER NOT NULL, tier INTEGER NOT NULL, path TEXT NOT NULL, name TEXT NOT NULL,
                bytes_written INTEGER NOT NULL, ts REAL NOT NULL,
                PRIMARY KEY(period, tier, path)) WITHOUT ROWID;
            """)
    }

    /// 阈值单位字节，0 关闭该档。超过（严格大于）阈值且本时段未提醒过的路径，在同一事务里记录并返回；任一步骤失败整体回滚并返回空（下次重试）。
    func checkWriteAlerts(hourBytes: UInt64, dayBytes: UInt64, now: Date, calendar: Calendar = .current) -> [WriteAlertRecord] {
        var found: [(tier: WriteAlertTier, period: Int, path: String, name: String, bytes: Int64)] = []
        func scan(_ sql: String, key: Int, limit: UInt64, tier: WriteAlertTier) {
            guard limit > 0, let s = prepare(sql) else { return }
            defer { sqlite3_finalize(s) }
            sqlite3_bind_int64(s, 1, Int64(key)); sqlite3_bind_int64(s, 2, Int64(clamping: limit))
            while sqlite3_step(s) == SQLITE_ROW {
                let path = text(s, 0) ?? ""
                let name = text(s, 1).flatMap { $0.isEmpty ? nil : $0 } ?? (path as NSString).lastPathComponent
                found.append((tier, key, path, name, sqlite3_column_int64(s, 2)))
            }
        }
        scan("""
            SELECT h.path, (SELECT name FROM disk_days d WHERE d.path = h.path ORDER BY day DESC LIMIT 1), h.bytes_written
            FROM disk_hours h WHERE h.hour = ?1 AND h.bytes_written > ?2 ORDER BY h.path
            """, key: DayRange.hourKey(of: now, calendar: calendar), limit: hourBytes, tier: .hour)
        scan("SELECT path, name, bytes_written FROM disk_days WHERE day = ?1 AND bytes_written > ?2 ORDER BY path",
             key: DayRange.key(of: now, calendar: calendar), limit: dayBytes, tier: .day)
        guard !found.isEmpty, exec("BEGIN IMMEDIATE") else { return [] }
        guard let ins = prepare("INSERT OR IGNORE INTO write_alerts(period, tier, path, name, bytes_written, ts) VALUES(?,?,?,?,?,?)") else {
            exec("ROLLBACK"); return []
        }
        var fresh: [WriteAlertRecord] = []
        var ok = true
        for f in found {
            sqlite3_reset(ins)
            sqlite3_bind_int64(ins, 1, Int64(f.period)); sqlite3_bind_int64(ins, 2, Int64(f.tier.rawValue))
            bind(ins, 3, f.path); bind(ins, 4, f.name)
            sqlite3_bind_int64(ins, 5, f.bytes); sqlite3_bind_double(ins, 6, now.timeIntervalSince1970)
            if sqlite3_step(ins) != SQLITE_DONE { ok = false; break }
            if sqlite3_changes(db) == 1 {
                fresh.append(WriteAlertRecord(date: now, tier: f.tier, path: f.path, name: f.name, bytesWritten: UInt64(max(f.bytes, 0))))
            }
        }
        sqlite3_finalize(ins)
        if ok, exec("COMMIT") { return fresh }
        exec("ROLLBACK")
        return []
    }

    /// 最近的提醒记录，新的在前。
    func recentWriteAlerts(limit: Int = 100) -> [WriteAlertRecord] {
        guard let s = prepare("SELECT ts, tier, path, name, bytes_written FROM write_alerts ORDER BY ts DESC, path LIMIT ?") else { return [] }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_int64(s, 1, Int64(limit))
        var r: [WriteAlertRecord] = []
        while sqlite3_step(s) == SQLITE_ROW {
            r.append(WriteAlertRecord(date: Date(timeIntervalSince1970: sqlite3_column_double(s, 0)),
                                      tier: WriteAlertTier(rawValue: Int(sqlite3_column_int64(s, 1))) ?? .hour,
                                      path: text(s, 2) ?? "", name: text(s, 3) ?? "",
                                      bytesWritten: UInt64(max(sqlite3_column_int64(s, 4), 0))))
        }
        return r
    }

    func pruneWriteAlerts(now: Date) {
        if let s = prepare("DELETE FROM write_alerts WHERE ts < ?") {
            sqlite3_bind_double(s, 1, now.timeIntervalSince1970 - Double(HistoryStore.writeAlertRetentionDays * 86_400))
            sqlite3_step(s); sqlite3_finalize(s)
        }
    }
}
