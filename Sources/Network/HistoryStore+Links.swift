//
//  HistoryStore+Links.swift
//  Zest
//
//  链路账本的历史存储：规则 × 出口 × 应用日汇总（含未归属行）永久保留；
//  域名日记录保留 30 天；小时数据保留 24 小时。只有主进程写入，查看器（migrate: false）不建表不写。
//

import Foundation
import SQLite3

extension HistoryStore {
    static let domainRetentionDays = 30
    /// shortcut: 小时数据只留 24 小时，柱图只能画最近 24 小时；需要更长的小时柱图时再延长这个保留期（并同步 prune 与图表范围）。
    static let linkHourRetention = 24

    func createLinkTables() -> Bool {
        exec("""
            CREATE TABLE IF NOT EXISTS link_days(
                day INTEGER NOT NULL, rule TEXT NOT NULL, egress TEXT NOT NULL, app TEXT NOT NULL,
                bytes_in INTEGER NOT NULL, bytes_out INTEGER NOT NULL,
                PRIMARY KEY(day, rule, egress, app)) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS link_domains(
                day INTEGER NOT NULL, host TEXT NOT NULL, rule TEXT NOT NULL, egress TEXT NOT NULL, app TEXT NOT NULL,
                bytes_in INTEGER NOT NULL, bytes_out INTEGER NOT NULL,
                PRIMARY KEY(day, host, rule, egress, app)) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS link_hours(
                hour INTEGER NOT NULL, rule TEXT NOT NULL, egress TEXT NOT NULL, app TEXT NOT NULL,
                bytes_in INTEGER NOT NULL, bytes_out INTEGER NOT NULL,
                PRIMARY KEY(hour, rule, egress, app)) WITHOUT ROWID;
            """)
    }

    func clearLinks() {
        guard exec("BEGIN") else { return }
        if !exec("DELETE FROM link_days; DELETE FROM link_domains; DELETE FROM link_hours") || !exec("COMMIT") { exec("ROLLBACK") }
    }

    func pruneLinks(now: Date, calendar: Calendar) {
        if let cut = calendar.date(byAdding: .day, value: -HistoryStore.domainRetentionDays, to: now),
           let s = prepare("DELETE FROM link_domains WHERE day < ?") {
            sqlite3_bind_int64(s, 1, Int64(DayRange.key(of: cut, calendar: calendar))); sqlite3_step(s); sqlite3_finalize(s)
        }
        if let cut = calendar.date(byAdding: .hour, value: -HistoryStore.linkHourRetention, to: now),
           let s = prepare("DELETE FROM link_hours WHERE hour < ?") {
            sqlite3_bind_int64(s, 1, Int64(DayRange.hourKey(of: cut, calendar: calendar))); sqlite3_step(s); sqlite3_finalize(s)
        }
    }

    // MARK: 写入

    /// 单事务累加一批链路增量。任一步骤失败整体回滚并返回 false（调用方保留增量以便重试）。
    @discardableResult
    func addLinks(_ d: LedgerDelta) -> Bool {
        guard !d.isEmpty else { return true }
        guard exec("BEGIN") else { return false }
        var ok = true
        func upsert(_ table: String, _ keys: String, _ n: Int) -> OpaquePointer? {
            prepare("""
                INSERT INTO \(table)(\(keys), bytes_in, bytes_out) VALUES(\(Array(repeating: "?", count: n + 2).joined(separator: ",")))
                ON CONFLICT DO UPDATE SET bytes_in = bytes_in + excluded.bytes_in, bytes_out = bytes_out + excluded.bytes_out
                """)
        }
        func run(_ s: OpaquePointer, _ ints: [Int], _ texts: [String], _ t: LedgerTraffic) {
            sqlite3_reset(s)
            var i: Int32 = 1
            for v in ints { sqlite3_bind_int64(s, i, Int64(v)); i += 1 }
            for v in texts { bind(s, i, v); i += 1 }
            sqlite3_bind_int64(s, i, t.down); sqlite3_bind_int64(s, i + 1, t.up)
            if sqlite3_step(s) != SQLITE_DONE { ok = false }
        }
        if let days = upsert("link_days", "day, rule, egress, app", 4) {
            for (k, v) in d.routes { run(days, [k.day], [k.rule, k.exit, k.app], v) }
            for (day, v) in d.unattributed { run(days, [day], [LinkKey.unattributed, "", ""], v) }
            sqlite3_finalize(days)
        } else { ok = false }
        if let dom = upsert("link_domains", "day, host, rule, egress, app", 5) {
            for (k, v) in d.domains { run(dom, [k.day], [k.host, k.rule, k.exit, k.app], v) }
            sqlite3_finalize(dom)
        } else { ok = false }
        if let hrs = upsert("link_hours", "hour, rule, egress, app", 4) {
            for (k, v) in d.hours { run(hrs, [k.hour], [k.rule, k.exit, k.app], v) }
            for (h, v) in d.unattributedHours { run(hrs, [h], [LinkKey.unattributed, "", ""], v) }
            sqlite3_finalize(hrs)
        } else { ok = false }
        if ok, exec("COMMIT") { return true }
        exec("ROLLBACK")
        return false
    }

    // MARK: 查询

    /// 范围内按规则、出口、应用汇总的行（含未归属行，规则列为 LinkKey.unattributed）。
    func linkRows(_ range: DayRange) -> [(rule: String, exit: String, app: String, traffic: LedgerTraffic)] {
        guard let s = prepare("""
            SELECT rule, egress, app, SUM(bytes_in), SUM(bytes_out) FROM link_days
            WHERE day >= ? AND day <= ? GROUP BY rule, egress, app
            """) else { return [] }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_int64(s, 1, Int64(range.from)); sqlite3_bind_int64(s, 2, Int64(range.to))
        var r: [(String, String, String, LedgerTraffic)] = []
        while sqlite3_step(s) == SQLITE_ROW {
            r.append((text(s, 0) ?? "", text(s, 1) ?? "", text(s, 2) ?? "",
                      LedgerTraffic(down: sqlite3_column_int64(s, 3), up: sqlite3_column_int64(s, 4))))
        }
        return r
    }

    /// 范围内域名汇总（只含 30 天内的记录），可限定规则。
    func linkDomains(_ range: DayRange, rule: String?, filter: LinkFilter = LinkFilter()) -> [LinkGroup] {
        guard let s = prepare("""
            SELECT host, rule, egress, app, SUM(bytes_in), SUM(bytes_out) FROM link_domains
            WHERE day >= ?1 AND day <= ?2\(rule == nil ? "" : " AND rule = ?3") GROUP BY host, rule, egress, app
            """) else { return [] }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_int64(s, 1, Int64(range.from)); sqlite3_bind_int64(s, 2, Int64(range.to))
        if let rule { bind(s, 3, rule) }
        var rows: [(name: String, traffic: LedgerTraffic)] = []
        while sqlite3_step(s) == SQLITE_ROW {
            let host = text(s, 0) ?? ""
            guard filter.matches(rule: text(s, 1) ?? "", exit: text(s, 2) ?? "", app: text(s, 3) ?? "", host: host) else { continue }
            rows.append((host, LedgerTraffic(down: sqlite3_column_int64(s, 4), up: sqlite3_column_int64(s, 5))))
        }
        return LinkSnapshot.groups(rows)
    }

    private func bars(_ table: String, column: String, keys: [Int], rule: String?, filter: LinkFilter) -> [LinkBar] {
        guard let lo = keys.first, let hi = keys.last,
              let s = prepare("""
                SELECT \(column), rule, egress, app, SUM(bytes_in), SUM(bytes_out) FROM \(table)
                WHERE \(column) >= ?1 AND \(column) <= ?2\(rule == nil ? "" : " AND rule = ?3") GROUP BY \(column), rule, egress, app
                """) else { return keys.map { LinkBar(key: $0, traffic: LedgerTraffic()) } }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_int64(s, 1, Int64(lo)); sqlite3_bind_int64(s, 2, Int64(hi))
        if let rule { bind(s, 3, rule) }
        var m: [Int: LedgerTraffic] = [:]
        while sqlite3_step(s) == SQLITE_ROW {
            guard filter.matches(rule: text(s, 1) ?? "", exit: text(s, 2) ?? "", app: text(s, 3) ?? "") else { continue }
            m[Int(sqlite3_column_int64(s, 0)), default: LedgerTraffic()].add(sqlite3_column_int64(s, 4), sqlite3_column_int64(s, 5))
        }
        return keys.map { LinkBar(key: $0, traffic: m[$0] ?? LedgerTraffic()) }
    }

    /// 最近 24 小时（含当前小时）每小时一根，从旧到新。
    func linkHourlyBars(now: Date, rule: String?, filter: LinkFilter = LinkFilter(), calendar: Calendar) -> [LinkBar] {
        let keys = (0..<HistoryStore.linkHourRetention).reversed().compactMap { back -> Int? in
            calendar.date(byAdding: .hour, value: -back, to: now).map { DayRange.hourKey(of: $0, calendar: calendar) }
        }
        return bars("link_hours", column: "hour", keys: keys, rule: rule, filter: filter)
    }

    /// 链路页一次查询：规则始终列全部；出口、应用、域名、柱图与总量按 rule 过滤；未归属只在未选规则时有值。
    func linkSnapshot(_ range: TotalsRange, rule: String?, filter: LinkFilter = LinkFilter(), now: Date = Date(), calendar: Calendar = .current) -> LinkSnapshot {
        let days = range.dayRange(now: now, calendar: calendar)
        let cutoff = calendar.date(byAdding: .day, value: -HistoryStore.domainRetentionDays, to: now)
            .map { DayRange.key(of: $0, calendar: calendar) } ?? 0
        let rec = linkExportRecords(days, domains: filter.hasSearch)
        let real = filter.pick(days: rec.days, domains: rec.domains, cutoff: cutoff, rule: nil).filter { $0.rule != LinkKey.unattributed }
        let scopedAll = filter.pick(days: rec.days, domains: rec.domains, cutoff: cutoff, rule: rule)
        let scoped = scopedAll.filter { $0.rule != LinkKey.unattributed }
        var snap = LinkSnapshot()
        snap.rules = LinkSnapshot.groups(real.map { ($0.rule, $0.traffic) })
        snap.exits = LinkSnapshot.groups(scoped.map { ($0.exit, $0.traffic) })
        snap.apps = LinkSnapshot.groups(scoped.map { ($0.app, $0.traffic) })
        for r in scopedAll where r.rule == LinkKey.unattributed { snap.unattributed.add(r.traffic.down, r.traffic.up) }
        snap.total = snap.unattributed
        for r in scoped { snap.total.add(r.traffic.down, r.traffic.up) }
        snap.domains = linkDomains(days, rule: rule, filter: filter)
        snap.hourly = linkHourlyBars(now: now, rule: rule, filter: filter, calendar: calendar)
        var perDay: [Int: LedgerTraffic] = [:]
        for r in scopedAll { perDay[r.day, default: LedgerTraffic()].add(r.traffic.down, r.traffic.up) }
        snap.daily = days.days(calendar: calendar).map { LinkBar(key: $0, traffic: perDay[$0] ?? LedgerTraffic()) }
        return snap
    }

    // MARK: 导出

    /// 范围内的日汇总行与域名行（未筛选），交给 LinkCSV 组装。
    func linkExportRecords(_ range: DayRange, domains withDomains: Bool = true) -> (days: [LinkExportRecord], domains: [LinkExportRecord]) {
        func fetch(_ sql: String, hasHost: Bool) -> [LinkExportRecord] {
            guard let s = prepare(sql) else { return [] }
            defer { sqlite3_finalize(s) }
            sqlite3_bind_int64(s, 1, Int64(range.from)); sqlite3_bind_int64(s, 2, Int64(range.to))
            var r: [LinkExportRecord] = []
            let o: Int32 = hasHost ? 1 : 0
            while sqlite3_step(s) == SQLITE_ROW {
                r.append(LinkExportRecord(day: Int(sqlite3_column_int64(s, 0)), host: hasHost ? (text(s, 1) ?? "") : nil,
                                          rule: text(s, 1 + o) ?? "", exit: text(s, 2 + o) ?? "", app: text(s, 3 + o) ?? "",
                                          traffic: LedgerTraffic(down: sqlite3_column_int64(s, 4 + o), up: sqlite3_column_int64(s, 5 + o))))
            }
            return r
        }
        return (fetch("SELECT day, rule, egress, app, bytes_in, bytes_out FROM link_days WHERE day >= ?1 AND day <= ?2", hasHost: false),
                withDomains ? fetch("SELECT day, host, rule, egress, app, bytes_in, bytes_out FROM link_domains WHERE day >= ?1 AND day <= ?2", hasHost: true) : [])
    }
}
