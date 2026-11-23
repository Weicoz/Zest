//
//  HistoryStore+Nodes.swift
//  Zest
//
//  Bettbox 代理节点与分组出口连通监测历史存储（schema v2）：
//  - node_meta：记录节点表口径版本；从 v1 升级到 v2 时仅重置旧口径 node_* 表，不触碰流量/链路/磁盘表；
//  - node_probes：单次探测明细，主键 (node, dialer, ts_ms) 幂等去重，保留 72 小时；
//  - node_hours：按本地小时 × 来源聚合，保留 7 天（滚动 24 小时指标与状态条）；
//  - node_days：按本地自然日 × 来源聚合，永久保留（7 天 / 30 天在线率与加权平均延时）；
//  - group_watch_hours（7 天）、group_watch_days（永久）、group_watch_latest：选定分组服务通道统计与断线计数。
//  只有主进程建表、写入、清理；网络窗口进程（migrate: false）完全只读。
//

import Foundation
import SQLite3

extension HistoryStore {
    static let nodeSchemaVersion = 2
    static let nodeProbeRetentionHours = 72
    static let nodeHourRetentionDays = 7
    /// 分组连续失败计数的时间连续窗口（20 分钟 = 4 个 5 分钟周期）：跨休眠、退应用或久未监测后自动清零重新计数。
    static let groupFailureContinuityWindowMs: Int64 = 20 * 60 * 1000
    static let groupLatestRetentionDays = 30

    func createNodeTables() -> Bool {
        // 只读快路径：已完成当前版本建表时无需抢占写锁（避免主进程多连接启动时串行跑 DDL）。
        if nodeTablesReadyInDB() { return true }

        guard exec("BEGIN IMMEDIATE") else { return false }
        guard exec("CREATE TABLE IF NOT EXISTS node_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;") else {
            exec("ROLLBACK")
            return false
        }
        guard let currentVersion = nodeSchemaVersionInDB() else {
            exec("ROLLBACK")
            return false
        }
        var ok = true
        if currentVersion < HistoryStore.nodeSchemaVersion {
            // 从 v1 升级到 v2：旧表缺少 source 列且包含未清洗的超时边界假值与多组重复样本，仅重建 node_* 表。
            ok = exec("""
                DROP TABLE IF EXISTS node_probes;
                DROP TABLE IF EXISTS node_hours;
                DROP TABLE IF EXISTS node_days;
                """)
        }
        if ok {
            ok = exec("""
                CREATE TABLE IF NOT EXISTS node_probes(
                    ts_ms INTEGER NOT NULL,
                    node TEXT NOT NULL,
                    dialer TEXT NOT NULL,
                    node_type TEXT NOT NULL,
                    delay_ms INTEGER NOT NULL,
                    ok INTEGER NOT NULL,
                    source INTEGER NOT NULL,
                    PRIMARY KEY(node, dialer, ts_ms)) WITHOUT ROWID;
                CREATE INDEX IF NOT EXISTS node_probes_ts ON node_probes(ts_ms);
                CREATE TABLE IF NOT EXISTS node_hours(
                    hour INTEGER NOT NULL,
                    node TEXT NOT NULL,
                    dialer TEXT NOT NULL,
                    source INTEGER NOT NULL,
                    probes INTEGER NOT NULL,
                    ok INTEGER NOT NULL,
                    sum_delay_ms INTEGER NOT NULL,
                    min_delay_ms INTEGER NOT NULL,
                    max_delay_ms INTEGER NOT NULL,
                    PRIMARY KEY(hour, node, dialer, source)) WITHOUT ROWID;
                CREATE TABLE IF NOT EXISTS node_days(
                    day INTEGER NOT NULL,
                    node TEXT NOT NULL,
                    dialer TEXT NOT NULL,
                    source INTEGER NOT NULL,
                    node_type TEXT NOT NULL,
                    probes INTEGER NOT NULL,
                    ok INTEGER NOT NULL,
                    sum_delay_ms INTEGER NOT NULL,
                    min_delay_ms INTEGER NOT NULL,
                    max_delay_ms INTEGER NOT NULL,
                    PRIMARY KEY(day, node, dialer, source)) WITHOUT ROWID;
                CREATE TABLE IF NOT EXISTS group_watch_hours(
                    hour INTEGER NOT NULL,
                    profile_id TEXT NOT NULL,
                    group_name TEXT NOT NULL,
                    probes INTEGER NOT NULL,
                    ok INTEGER NOT NULL,
                    sum_delay_ms INTEGER NOT NULL,
                    min_delay_ms INTEGER NOT NULL,
                    max_delay_ms INTEGER NOT NULL,
                    PRIMARY KEY(hour, profile_id, group_name)) WITHOUT ROWID;
                CREATE TABLE IF NOT EXISTS group_watch_days(
                    day INTEGER NOT NULL,
                    profile_id TEXT NOT NULL,
                    group_name TEXT NOT NULL,
                    current_node TEXT NOT NULL,
                    probes INTEGER NOT NULL,
                    ok INTEGER NOT NULL,
                    sum_delay_ms INTEGER NOT NULL,
                    min_delay_ms INTEGER NOT NULL,
                    max_delay_ms INTEGER NOT NULL,
                    PRIMARY KEY(day, profile_id, group_name)) WITHOUT ROWID;
                CREATE TABLE IF NOT EXISTS group_watch_latest(
                    profile_id TEXT NOT NULL,
                    group_name TEXT NOT NULL,
                    ts_ms INTEGER NOT NULL,
                    current_node TEXT NOT NULL,
                    dialer TEXT NOT NULL,
                    ok INTEGER NOT NULL,
                    delay_ms INTEGER NOT NULL,
                    consecutive_failures INTEGER NOT NULL,
                    PRIMARY KEY(profile_id, group_name)) WITHOUT ROWID;
                """)
        }
        if ok && currentVersion < HistoryStore.nodeSchemaVersion {
            ok = exec("INSERT OR REPLACE INTO node_meta(key, value) VALUES('schema_version', '\(HistoryStore.nodeSchemaVersion)');")
        }
        if ok, exec("COMMIT") { return true }
        exec("ROLLBACK")
        return false
    }

    private func nodeTablesReadyInDB() -> Bool {
        guard let s = prepare("""
            SELECT COUNT(*) FROM sqlite_master
            WHERE type = 'table' AND name IN (
                'node_meta', 'node_probes', 'node_hours', 'node_days',
                'group_watch_hours', 'group_watch_days', 'group_watch_latest'
            )
            """) else { return false }
        let count = sqlite3_step(s) == SQLITE_ROW ? sqlite3_column_int(s, 0) : 0
        sqlite3_finalize(s)
        guard count == 7 else { return false }
        return (nodeSchemaVersionInDB() ?? 0) >= HistoryStore.nodeSchemaVersion
    }

    /// 返回当前数据库中的节点表版本：无记录返回 0，SQLite 准备/查询出错返回 nil（绝不误判为版本 0 触发删表）。
    private func nodeSchemaVersionInDB() -> Int? {
        guard let s = prepare("SELECT value FROM node_meta WHERE key = 'schema_version'") else { return nil }
        defer { sqlite3_finalize(s) }
        let rc = sqlite3_step(s)
        if rc == SQLITE_ROW {
            guard let str = text(s, 0), let v = Int(str) else { return 0 }
            return v
        }
        if rc == SQLITE_DONE { return 0 }
        return nil
    }

    func clearNodes() {
        guard !readOnly else { return }
        guard exec("BEGIN IMMEDIATE") else { return }
        if !exec("""
            DELETE FROM node_probes;
            DELETE FROM node_hours;
            DELETE FROM node_days;
            DELETE FROM group_watch_hours;
            DELETE FROM group_watch_days;
            DELETE FROM group_watch_latest;
            """) || !exec("COMMIT") {
            exec("ROLLBACK")
        }
    }

    func pruneNodes(now: Date, calendar: Calendar) {
        guard !readOnly else { return }
        let probeCutoffMs = Int64(((now.timeIntervalSince1970 - Double(HistoryStore.nodeProbeRetentionHours * 3600)) * 1000.0).rounded())
        if let s = prepare("DELETE FROM node_probes WHERE ts_ms < ?") {
            sqlite3_bind_int64(s, 1, probeCutoffMs)
            sqlite3_step(s)
            sqlite3_finalize(s)
        }
        if let cut = calendar.date(byAdding: .day, value: -HistoryStore.nodeHourRetentionDays, to: now) {
            let hourCut = Int64(DayRange.hourKey(of: cut, calendar: calendar))
            if let s = prepare("DELETE FROM node_hours WHERE hour < ?") {
                sqlite3_bind_int64(s, 1, hourCut)
                sqlite3_step(s)
                sqlite3_finalize(s)
            }
            if let s = prepare("DELETE FROM group_watch_hours WHERE hour < ?") {
                sqlite3_bind_int64(s, 1, hourCut)
                sqlite3_step(s)
                sqlite3_finalize(s)
            }
        }
        let latestCutoffMs = Int64(((now.timeIntervalSince1970 - Double(HistoryStore.groupLatestRetentionDays * 86400)) * 1000.0).rounded())
        if let s = prepare("DELETE FROM group_watch_latest WHERE ts_ms < ?") {
            sqlite3_bind_int64(s, 1, latestCutoffMs)
            sqlite3_step(s)
            sqlite3_finalize(s)
        }
    }

    // MARK: 节点探测写入

    @discardableResult
    func addNodeProbes(_ samples: [NodeProbeSample], calendar: Calendar = .current) -> Bool {
        guard !readOnly else { return false }
        guard !samples.isEmpty else { return true }
        guard exec("BEGIN IMMEDIATE") else { return false }

        let probeSQL = """
            INSERT OR IGNORE INTO node_probes(ts_ms, node, dialer, node_type, delay_ms, ok, source)
            VALUES(?,?,?,?,?,?,?)
            """
        let hourSQL = """
            INSERT INTO node_hours(hour, node, dialer, source, probes, ok, sum_delay_ms, min_delay_ms, max_delay_ms)
            VALUES(?,?,?,?,1,?,?,?,?)
            ON CONFLICT(hour, node, dialer, source) DO UPDATE SET
                probes = probes + 1,
                ok = ok + excluded.ok,
                sum_delay_ms = sum_delay_ms + excluded.sum_delay_ms,
                min_delay_ms = CASE
                    WHEN excluded.ok = 0 THEN node_hours.min_delay_ms
                    WHEN node_hours.min_delay_ms = 0 THEN excluded.min_delay_ms
                    ELSE MIN(node_hours.min_delay_ms, excluded.min_delay_ms)
                END,
                max_delay_ms = MAX(node_hours.max_delay_ms, excluded.max_delay_ms)
            """
        let daySQL = """
            INSERT INTO node_days(day, node, dialer, source, node_type, probes, ok, sum_delay_ms, min_delay_ms, max_delay_ms)
            VALUES(?,?,?,?,?,1,?,?,?,?)
            ON CONFLICT(day, node, dialer, source) DO UPDATE SET
                node_type = excluded.node_type,
                probes = probes + 1,
                ok = ok + excluded.ok,
                sum_delay_ms = sum_delay_ms + excluded.sum_delay_ms,
                min_delay_ms = CASE
                    WHEN excluded.ok = 0 THEN node_days.min_delay_ms
                    WHEN node_days.min_delay_ms = 0 THEN excluded.min_delay_ms
                    ELSE MIN(node_days.min_delay_ms, excluded.min_delay_ms)
                END,
                max_delay_ms = MAX(node_days.max_delay_ms, excluded.max_delay_ms)
            """

        let pStmt = prepare(probeSQL)
        let hStmt = prepare(hourSQL)
        let dStmt = prepare(daySQL)
        guard let pStmt, let hStmt, let dStmt else {
            [pStmt, hStmt, dStmt].forEach { sqlite3_finalize($0) }
            exec("ROLLBACK")
            return false
        }

        var ok = true
        for s in samples {
            let isOk = s.ok && s.delayMs > 0
            let okInt: Int64 = isOk ? 1 : 0
            let delay: Int64 = isOk ? Int64(s.delayMs) : 0
            let srcInt = Int64(s.source.rawValue)

            sqlite3_reset(pStmt)
            sqlite3_bind_int64(pStmt, 1, s.tsMs)
            bind(pStmt, 2, s.node)
            bind(pStmt, 3, s.dialer)
            bind(pStmt, 4, s.nodeType)
            sqlite3_bind_int64(pStmt, 5, delay)
            sqlite3_bind_int64(pStmt, 6, okInt)
            sqlite3_bind_int64(pStmt, 7, srcInt)
            if sqlite3_step(pStmt) != SQLITE_DONE { ok = false; break }
            if sqlite3_changes(db) == 0 { continue }

            let date = Date(timeIntervalSince1970: Double(s.tsMs) / 1000.0)
            let hour = DayRange.hourKey(of: date, calendar: calendar)
            let day = DayRange.key(of: date, calendar: calendar)

            sqlite3_reset(hStmt)
            sqlite3_bind_int64(hStmt, 1, Int64(hour))
            bind(hStmt, 2, s.node)
            bind(hStmt, 3, s.dialer)
            sqlite3_bind_int64(hStmt, 4, srcInt)
            sqlite3_bind_int64(hStmt, 5, okInt)
            sqlite3_bind_int64(hStmt, 6, delay)
            sqlite3_bind_int64(hStmt, 7, delay)
            sqlite3_bind_int64(hStmt, 8, delay)
            if sqlite3_step(hStmt) != SQLITE_DONE { ok = false; break }

            sqlite3_reset(dStmt)
            sqlite3_bind_int64(dStmt, 1, Int64(day))
            bind(dStmt, 2, s.node)
            bind(dStmt, 3, s.dialer)
            sqlite3_bind_int64(dStmt, 4, srcInt)
            bind(dStmt, 5, s.nodeType)
            sqlite3_bind_int64(dStmt, 6, okInt)
            sqlite3_bind_int64(dStmt, 7, delay)
            sqlite3_bind_int64(dStmt, 8, delay)
            sqlite3_bind_int64(dStmt, 9, delay)
            if sqlite3_step(dStmt) != SQLITE_DONE { ok = false; break }
        }

        [pStmt, hStmt, dStmt].forEach { sqlite3_finalize($0) }
        if ok, exec("COMMIT") { return true }
        exec("ROLLBACK")
        return false
    }

    // MARK: 分组服务通道写入

    /// 单事务写入本轮分组通道探测结果，并返回每个分组更新后的连续失败次数（供连续 2 次断线通知判断）。
    @discardableResult
    func addGroupWatchSamples(_ samples: [GroupWatchSample], calendar: Calendar = .current) -> [String: Int]? {
        guard !readOnly else { return nil }
        guard !samples.isEmpty else { return [:] }
        guard exec("BEGIN IMMEDIATE") else { return nil }

        let readFailStmt = prepare("SELECT consecutive_failures, ts_ms FROM group_watch_latest WHERE profile_id = ?1 AND group_name = ?2")
        let hourStmt = prepare("""
            INSERT INTO group_watch_hours(hour, profile_id, group_name, probes, ok, sum_delay_ms, min_delay_ms, max_delay_ms)
            VALUES(?,?,?,1,?,?,?,?)
            ON CONFLICT(hour, profile_id, group_name) DO UPDATE SET
                probes = probes + 1,
                ok = ok + excluded.ok,
                sum_delay_ms = sum_delay_ms + excluded.sum_delay_ms,
                min_delay_ms = CASE
                    WHEN excluded.ok = 0 THEN group_watch_hours.min_delay_ms
                    WHEN group_watch_hours.min_delay_ms = 0 THEN excluded.min_delay_ms
                    ELSE MIN(group_watch_hours.min_delay_ms, excluded.min_delay_ms)
                END,
                max_delay_ms = MAX(group_watch_hours.max_delay_ms, excluded.max_delay_ms)
            """)
        let dayStmt = prepare("""
            INSERT INTO group_watch_days(day, profile_id, group_name, current_node, probes, ok, sum_delay_ms, min_delay_ms, max_delay_ms)
            VALUES(?,?,?,?,1,?,?,?,?)
            ON CONFLICT(day, profile_id, group_name) DO UPDATE SET
                current_node = excluded.current_node,
                probes = probes + 1,
                ok = ok + excluded.ok,
                sum_delay_ms = sum_delay_ms + excluded.sum_delay_ms,
                min_delay_ms = CASE
                    WHEN excluded.ok = 0 THEN group_watch_days.min_delay_ms
                    WHEN group_watch_days.min_delay_ms = 0 THEN excluded.min_delay_ms
                    ELSE MIN(group_watch_days.min_delay_ms, excluded.min_delay_ms)
                END,
                max_delay_ms = MAX(group_watch_days.max_delay_ms, excluded.max_delay_ms)
            """)
        let latestStmt = prepare("""
            INSERT OR REPLACE INTO group_watch_latest(
                profile_id, group_name, ts_ms, current_node, dialer, ok, delay_ms, consecutive_failures
            ) VALUES(?,?,?,?,?,?,?,?)
            """)

        guard let readFailStmt, let hourStmt, let dayStmt, let latestStmt else {
            [readFailStmt, hourStmt, dayStmt, latestStmt].forEach { sqlite3_finalize($0) }
            exec("ROLLBACK")
            return nil
        }

        var ok = true
        var failCounts: [String: Int] = [:]
        for s in samples {
            let isOk = s.ok && s.delayMs > 0
            let okInt: Int64 = isOk ? 1 : 0
            let delay: Int64 = isOk ? Int64(s.delayMs) : 0

            sqlite3_reset(readFailStmt)
            bind(readFailStmt, 1, s.profileId)
            bind(readFailStmt, 2, s.groupName)
            let prevFail: Int
            if sqlite3_step(readFailStmt) == SQLITE_ROW {
                let storedFail = Int(sqlite3_column_int64(readFailStmt, 0))
                let prevTsMs = sqlite3_column_int64(readFailStmt, 1)
                let continuous = s.tsMs >= prevTsMs && (s.tsMs - prevTsMs) <= HistoryStore.groupFailureContinuityWindowMs
                prevFail = continuous ? storedFail : 0
            } else {
                prevFail = 0
            }
            let nextFail = isOk ? 0 : (prevFail + 1)
            failCounts[s.groupName] = nextFail

            let date = Date(timeIntervalSince1970: Double(s.tsMs) / 1000.0)
            let hour = DayRange.hourKey(of: date, calendar: calendar)
            let day = DayRange.key(of: date, calendar: calendar)

            sqlite3_reset(hourStmt)
            sqlite3_bind_int64(hourStmt, 1, Int64(hour))
            bind(hourStmt, 2, s.profileId)
            bind(hourStmt, 3, s.groupName)
            sqlite3_bind_int64(hourStmt, 4, okInt)
            sqlite3_bind_int64(hourStmt, 5, delay)
            sqlite3_bind_int64(hourStmt, 6, delay)
            sqlite3_bind_int64(hourStmt, 7, delay)
            if sqlite3_step(hourStmt) != SQLITE_DONE { ok = false; break }

            sqlite3_reset(dayStmt)
            sqlite3_bind_int64(dayStmt, 1, Int64(day))
            bind(dayStmt, 2, s.profileId)
            bind(dayStmt, 3, s.groupName)
            bind(dayStmt, 4, s.currentNode)
            sqlite3_bind_int64(dayStmt, 5, okInt)
            sqlite3_bind_int64(dayStmt, 6, delay)
            sqlite3_bind_int64(dayStmt, 7, delay)
            sqlite3_bind_int64(dayStmt, 8, delay)
            if sqlite3_step(dayStmt) != SQLITE_DONE { ok = false; break }

            sqlite3_reset(latestStmt)
            bind(latestStmt, 1, s.profileId)
            bind(latestStmt, 2, s.groupName)
            sqlite3_bind_int64(latestStmt, 3, s.tsMs)
            bind(latestStmt, 4, s.currentNode)
            bind(latestStmt, 5, s.dialer)
            sqlite3_bind_int64(latestStmt, 6, okInt)
            sqlite3_bind_int64(latestStmt, 7, delay)
            sqlite3_bind_int64(latestStmt, 8, Int64(nextFail))
            if sqlite3_step(latestStmt) != SQLITE_DONE { ok = false; break }
        }

        [readFailStmt, hourStmt, dayStmt, latestStmt].forEach { sqlite3_finalize($0) }
        if ok, exec("COMMIT") { return failCounts }
        exec("ROLLBACK")
        return nil
    }

    // MARK: 节点查询

    func nodeLatestProbeTimestamps() -> [NodeKey: Int64] {
        guard let s = prepare("SELECT node, dialer, MAX(ts_ms) FROM node_probes GROUP BY node, dialer") else { return [:] }
        defer { sqlite3_finalize(s) }
        var result: [NodeKey: Int64] = [:]
        while sqlite3_step(s) == SQLITE_ROW {
            let key = NodeKey(name: text(s, 0) ?? "", dialer: text(s, 1) ?? "")
            result[key] = sqlite3_column_int64(s, 2)
        }
        return result
    }

    /// 一次性查询全部历史节点的 1 天（滚动 24 小时）、7 天、30 天指标、最新探测及 24h 状态条；支持按来源筛选。
    func nodeSummaries(sourceFilter: NodeSourceFilter = .all,
                       now: Date = Date(), calendar: Calendar = .current) -> [NodeKey: NodeSummaryRecord] {
        let hourKeys24 = lastHourKeys(count: 24, now: now, calendar: calendar)
        guard let hourFrom = hourKeys24.first, let hourTo = hourKeys24.last else { return [:] }
        let today = calendar.startOfDay(for: now)
        let dayTo = DayRange.key(of: today, calendar: calendar)
        let day7From = DayRange.key(of: calendar.date(byAdding: .day, value: -6, to: today) ?? today, calendar: calendar)
        let day30From = DayRange.key(of: calendar.date(byAdding: .day, value: -29, to: today) ?? today, calendar: calendar)
        let srcClause = sourceFilter == .activeOnly ? " AND source = \(NodeProbeSource.active.rawValue)" : ""

        var records: [NodeKey: NodeSummaryRecord] = [:]
        var hourlyMap: [NodeKey: [Int: NodeWindowMetrics]] = [:]

        // 1) 最近 24 小时逐小时与 1 天滚动汇总（按 source 合并）
        if let s = prepare("""
            SELECT hour, node, dialer, SUM(probes), SUM(ok), SUM(sum_delay_ms),
                   COALESCE(MIN(CASE WHEN min_delay_ms > 0 THEN min_delay_ms END), 0),
                   COALESCE(MAX(max_delay_ms), 0)
            FROM node_hours WHERE hour >= ?1 AND hour <= ?2\(srcClause)
            GROUP BY hour, node, dialer
            """) {
            sqlite3_bind_int64(s, 1, Int64(hourFrom))
            sqlite3_bind_int64(s, 2, Int64(hourTo))
            while sqlite3_step(s) == SQLITE_ROW {
                let hour = Int(sqlite3_column_int64(s, 0))
                let key = NodeKey(name: text(s, 1) ?? "", dialer: text(s, 2) ?? "")
                let m = metricsFromColumns(s, probesCol: 3, okCol: 4, sumCol: 5, minCol: 6, maxCol: 7)
                hourlyMap[key, default: [:]][hour] = m
                var rec = records[key] ?? NodeSummaryRecord(key: key, nodeType: "")
                rec.day1.merge(m)
                records[key] = rec
            }
            sqlite3_finalize(s)
        }

        // 2) 最近 30 天日汇总（同时聚合 7 天与 30 天）
        if let s = prepare("""
            SELECT day, node, dialer, MAX(node_type), SUM(probes), SUM(ok), SUM(sum_delay_ms),
                   COALESCE(MIN(CASE WHEN min_delay_ms > 0 THEN min_delay_ms END), 0),
                   COALESCE(MAX(max_delay_ms), 0)
            FROM node_days WHERE day >= ?1 AND day <= ?2\(srcClause)
            GROUP BY day, node, dialer ORDER BY day ASC
            """) {
            sqlite3_bind_int64(s, 1, Int64(day30From))
            sqlite3_bind_int64(s, 2, Int64(dayTo))
            while sqlite3_step(s) == SQLITE_ROW {
                let day = Int(sqlite3_column_int64(s, 0))
                let key = NodeKey(name: text(s, 1) ?? "", dialer: text(s, 2) ?? "")
                let nodeType = text(s, 3) ?? ""
                let m = metricsFromColumns(s, probesCol: 4, okCol: 5, sumCol: 6, minCol: 7, maxCol: 8)
                var rec = records[key] ?? NodeSummaryRecord(key: key, nodeType: nodeType)
                if !nodeType.isEmpty { rec.nodeType = nodeType }
                rec.day30.merge(m)
                if day >= day7From { rec.day7.merge(m) }
                records[key] = rec
            }
            sqlite3_finalize(s)
        }

        // 3) 最近一次探测记录（走聚集主键顺序扫描，无回表）
        let probeWhere = sourceFilter == .activeOnly ? " WHERE source = \(NodeProbeSource.active.rawValue)" : ""
        if let s = prepare("""
            SELECT MAX(ts_ms), node, dialer, node_type, delay_ms, ok, source
            FROM node_probes\(probeWhere) GROUP BY node, dialer
            """) {
            while sqlite3_step(s) == SQLITE_ROW {
                let tsMs = sqlite3_column_int64(s, 0)
                let key = NodeKey(name: text(s, 1) ?? "", dialer: text(s, 2) ?? "")
                let nodeType = text(s, 3) ?? ""
                let delayMs = Int(sqlite3_column_int64(s, 4))
                let isOk = sqlite3_column_int64(s, 5) != 0
                let src = NodeProbeSource(rawValue: Int(sqlite3_column_int64(s, 6))) ?? .passive
                var rec = records[key] ?? NodeSummaryRecord(key: key, nodeType: nodeType)
                if rec.nodeType.isEmpty, !nodeType.isEmpty { rec.nodeType = nodeType }
                rec.latest = NodeLatestProbe(tsMs: tsMs, ok: isOk, delayMs: delayMs, source: src)
                records[key] = rec
            }
            sqlite3_finalize(s)
        }

        for key in records.keys {
            let map = hourlyMap[key] ?? [:]
            records[key]?.hourly24 = hourKeys24.map { NodeHourPoint(hour: $0, metrics: map[$0] ?? NodeWindowMetrics()) }
        }
        return records
    }

    func nodeHourlySeries(key: NodeKey, hours: Int, sourceFilter: NodeSourceFilter = .all,
                          now: Date = Date(), calendar: Calendar = .current) -> [NodeHourPoint] {
        let keys = lastHourKeys(count: max(hours, 1), now: now, calendar: calendar)
        guard let lo = keys.first, let hi = keys.last else { return [] }
        let srcClause = sourceFilter == .activeOnly ? " AND source = \(NodeProbeSource.active.rawValue)" : ""
        var map: [Int: NodeWindowMetrics] = [:]
        if let s = prepare("""
            SELECT hour, SUM(probes), SUM(ok), SUM(sum_delay_ms),
                   COALESCE(MIN(CASE WHEN min_delay_ms > 0 THEN min_delay_ms END), 0),
                   COALESCE(MAX(max_delay_ms), 0)
            FROM node_hours WHERE node = ?1 AND dialer = ?2 AND hour >= ?3 AND hour <= ?4\(srcClause)
            GROUP BY hour
            """) {
            bind(s, 1, key.name)
            bind(s, 2, key.dialer)
            sqlite3_bind_int64(s, 3, Int64(lo))
            sqlite3_bind_int64(s, 4, Int64(hi))
            while sqlite3_step(s) == SQLITE_ROW {
                let h = Int(sqlite3_column_int64(s, 0))
                map[h] = metricsFromColumns(s, probesCol: 1, okCol: 2, sumCol: 3, minCol: 4, maxCol: 5)
            }
            sqlite3_finalize(s)
        }
        return keys.map { NodeHourPoint(hour: $0, metrics: map[$0] ?? NodeWindowMetrics()) }
    }

    func nodeDailySeries(key: NodeKey, days: Int, sourceFilter: NodeSourceFilter = .all,
                         now: Date = Date(), calendar: Calendar = .current) -> [NodeDayPoint] {
        let today = calendar.startOfDay(for: now)
        let fromDate = calendar.date(byAdding: .day, value: -(max(days, 1) - 1), to: today) ?? today
        let range = DayRange(from: DayRange.key(of: fromDate, calendar: calendar),
                             to: DayRange.key(of: today, calendar: calendar))
        let dayKeys = range.days(calendar: calendar)
        let srcClause = sourceFilter == .activeOnly ? " AND source = \(NodeProbeSource.active.rawValue)" : ""
        var map: [Int: NodeWindowMetrics] = [:]
        if let s = prepare("""
            SELECT day, SUM(probes), SUM(ok), SUM(sum_delay_ms),
                   COALESCE(MIN(CASE WHEN min_delay_ms > 0 THEN min_delay_ms END), 0),
                   COALESCE(MAX(max_delay_ms), 0)
            FROM node_days WHERE node = ?1 AND dialer = ?2 AND day >= ?3 AND day <= ?4\(srcClause)
            GROUP BY day
            """) {
            bind(s, 1, key.name)
            bind(s, 2, key.dialer)
            sqlite3_bind_int64(s, 3, Int64(range.from))
            sqlite3_bind_int64(s, 4, Int64(range.to))
            while sqlite3_step(s) == SQLITE_ROW {
                let d = Int(sqlite3_column_int64(s, 0))
                map[d] = metricsFromColumns(s, probesCol: 1, okCol: 2, sumCol: 3, minCol: 4, maxCol: 5)
            }
            sqlite3_finalize(s)
        }
        return dayKeys.map { NodeDayPoint(day: $0, metrics: map[$0] ?? NodeWindowMetrics()) }
    }

    /// 一次性读取全部节点在最近 N 小时内的分小时统计（供自定义分组趋势聚合在内存中极速切分，避免 N+1 查询）。
    func nodeAllHourlySeries(hours: Int, sourceFilter: NodeSourceFilter = .all,
                             now: Date = Date(), calendar: Calendar = .current) -> (keys: [Int], byNode: [NodeKey: [Int: NodeWindowMetrics]]) {
        let keys = lastHourKeys(count: max(hours, 1), now: now, calendar: calendar)
        guard let lo = keys.first, let hi = keys.last else { return ([], [:]) }
        let srcClause = sourceFilter == .activeOnly ? " AND source = \(NodeProbeSource.active.rawValue)" : ""
        var byNode: [NodeKey: [Int: NodeWindowMetrics]] = [:]
        if let s = prepare("""
            SELECT hour, node, dialer, SUM(probes), SUM(ok), SUM(sum_delay_ms),
                   COALESCE(MIN(CASE WHEN min_delay_ms > 0 THEN min_delay_ms END), 0),
                   COALESCE(MAX(max_delay_ms), 0)
            FROM node_hours WHERE hour >= ?1 AND hour <= ?2\(srcClause)
            GROUP BY hour, node, dialer
            """) {
            sqlite3_bind_int64(s, 1, Int64(lo))
            sqlite3_bind_int64(s, 2, Int64(hi))
            while sqlite3_step(s) == SQLITE_ROW {
                let h = Int(sqlite3_column_int64(s, 0))
                let key = NodeKey(name: text(s, 1) ?? "", dialer: text(s, 2) ?? "")
                byNode[key, default: [:]][h] = metricsFromColumns(s, probesCol: 3, okCol: 4, sumCol: 5, minCol: 6, maxCol: 7)
            }
            sqlite3_finalize(s)
        }
        return (keys, byNode)
    }

    /// 一次性读取全部节点在最近 N 个自然日内的分日统计（供自定义分组 7d / 30d 趋势对比复用）。
    func nodeAllDailySeries(days: Int, sourceFilter: NodeSourceFilter = .all,
                            now: Date = Date(), calendar: Calendar = .current) -> (keys: [Int], byNode: [NodeKey: [Int: NodeWindowMetrics]]) {
        let today = calendar.startOfDay(for: now)
        let fromDate = calendar.date(byAdding: .day, value: -(max(days, 1) - 1), to: today) ?? today
        let range = DayRange(from: DayRange.key(of: fromDate, calendar: calendar),
                             to: DayRange.key(of: today, calendar: calendar))
        let dayKeys = range.days(calendar: calendar)
        let srcClause = sourceFilter == .activeOnly ? " AND source = \(NodeProbeSource.active.rawValue)" : ""
        var byNode: [NodeKey: [Int: NodeWindowMetrics]] = [:]
        if let s = prepare("""
            SELECT day, node, dialer, SUM(probes), SUM(ok), SUM(sum_delay_ms),
                   COALESCE(MIN(CASE WHEN min_delay_ms > 0 THEN min_delay_ms END), 0),
                   COALESCE(MAX(max_delay_ms), 0)
            FROM node_days WHERE day >= ?1 AND day <= ?2\(srcClause)
            GROUP BY day, node, dialer
            """) {
            sqlite3_bind_int64(s, 1, Int64(range.from))
            sqlite3_bind_int64(s, 2, Int64(range.to))
            while sqlite3_step(s) == SQLITE_ROW {
                let d = Int(sqlite3_column_int64(s, 0))
                let key = NodeKey(name: text(s, 1) ?? "", dialer: text(s, 2) ?? "")
                byNode[key, default: [:]][d] = metricsFromColumns(s, probesCol: 3, okCol: 4, sumCol: 5, minCol: 6, maxCol: 7)
            }
            sqlite3_finalize(s)
        }
        return (dayKeys, byNode)
    }

    // MARK: 分组服务通道查询

    /// 查询指定 Bettbox 配置下所有有记录的分组通道 1d / 7d / 30d 统计与最新状态。
    func groupWatchSummaries(profileId: String, now: Date = Date(),
                             calendar: Calendar = .current) -> [String: GroupWatchSummaryRecord] {
        let hourKeys24 = lastHourKeys(count: 24, now: now, calendar: calendar)
        guard let hourFrom = hourKeys24.first, let hourTo = hourKeys24.last else { return [:] }
        let today = calendar.startOfDay(for: now)
        let dayTo = DayRange.key(of: today, calendar: calendar)
        let day7From = DayRange.key(of: calendar.date(byAdding: .day, value: -6, to: today) ?? today, calendar: calendar)
        let day30From = DayRange.key(of: calendar.date(byAdding: .day, value: -29, to: today) ?? today, calendar: calendar)

        var records: [String: GroupWatchSummaryRecord] = [:]
        var hourlyMap: [String: [Int: NodeWindowMetrics]] = [:]

        if let s = prepare("""
            SELECT hour, group_name, probes, ok, sum_delay_ms, min_delay_ms, max_delay_ms
            FROM group_watch_hours WHERE profile_id = ?1 AND hour >= ?2 AND hour <= ?3
            """) {
            bind(s, 1, profileId)
            sqlite3_bind_int64(s, 2, Int64(hourFrom))
            sqlite3_bind_int64(s, 3, Int64(hourTo))
            while sqlite3_step(s) == SQLITE_ROW {
                let hour = Int(sqlite3_column_int64(s, 0))
                let group = text(s, 1) ?? ""
                let m = metricsFromColumns(s, probesCol: 2, okCol: 3, sumCol: 4, minCol: 5, maxCol: 6)
                hourlyMap[group, default: [:]][hour] = m
                var rec = records[group] ?? GroupWatchSummaryRecord(groupName: group, currentNode: "", dialer: "")
                rec.day1.merge(m)
                records[group] = rec
            }
            sqlite3_finalize(s)
        }

        if let s = prepare("""
            SELECT day, group_name, current_node, probes, ok, sum_delay_ms, min_delay_ms, max_delay_ms
            FROM group_watch_days WHERE profile_id = ?1 AND day >= ?2 AND day <= ?3 ORDER BY day ASC
            """) {
            bind(s, 1, profileId)
            sqlite3_bind_int64(s, 2, Int64(day30From))
            sqlite3_bind_int64(s, 3, Int64(dayTo))
            while sqlite3_step(s) == SQLITE_ROW {
                let day = Int(sqlite3_column_int64(s, 0))
                let group = text(s, 1) ?? ""
                let node = text(s, 2) ?? ""
                let m = metricsFromColumns(s, probesCol: 3, okCol: 4, sumCol: 5, minCol: 6, maxCol: 7)
                var rec = records[group] ?? GroupWatchSummaryRecord(groupName: group, currentNode: node, dialer: "")
                if !node.isEmpty { rec.currentNode = node }
                rec.day30.merge(m)
                if day >= day7From { rec.day7.merge(m) }
                records[group] = rec
            }
            sqlite3_finalize(s)
        }

        if let s = prepare("""
            SELECT group_name, ts_ms, current_node, dialer, ok, delay_ms, consecutive_failures
            FROM group_watch_latest WHERE profile_id = ?1
            """) {
            bind(s, 1, profileId)
            while sqlite3_step(s) == SQLITE_ROW {
                let group = text(s, 0) ?? ""
                let tsMs = sqlite3_column_int64(s, 1)
                let node = text(s, 2) ?? ""
                let dialer = text(s, 3) ?? ""
                let isOk = sqlite3_column_int64(s, 4) != 0
                let delayMs = Int(sqlite3_column_int64(s, 5))
                let fails = Int(sqlite3_column_int64(s, 6))
                var rec = records[group] ?? GroupWatchSummaryRecord(groupName: group, currentNode: node, dialer: dialer)
                rec.currentNode = node
                rec.dialer = dialer
                rec.latest = GroupWatchLatest(tsMs: tsMs, currentNode: node, dialer: dialer,
                                              ok: isOk, delayMs: delayMs, consecutiveFailures: fails)
                records[group] = rec
            }
            sqlite3_finalize(s)
        }

        for g in records.keys {
            let map = hourlyMap[g] ?? [:]
            records[g]?.hourly24 = hourKeys24.map { NodeHourPoint(hour: $0, metrics: map[$0] ?? NodeWindowMetrics()) }
        }
        return records
    }

    private func lastHourKeys(count: Int, now: Date, calendar: Calendar) -> [Int] {
        var seen = Set<Int>()
        var result: [Int] = []
        result.reserveCapacity(count)
        var back = 0
        while result.count < count && back < count + 4 {
            if let d = calendar.date(byAdding: .hour, value: -back, to: now) {
                let k = DayRange.hourKey(of: d, calendar: calendar)
                if seen.insert(k).inserted { result.append(k) }
            }
            back += 1
        }
        return result.reversed()
    }

    private func metricsFromColumns(_ s: OpaquePointer, probesCol: Int32, okCol: Int32,
                                    sumCol: Int32, minCol: Int32, maxCol: Int32) -> NodeWindowMetrics {
        let minVal = Int(sqlite3_column_int64(s, minCol))
        let maxVal = Int(sqlite3_column_int64(s, maxCol))
        return NodeWindowMetrics(
            probes: Int(max(sqlite3_column_int64(s, probesCol), 0)),
            ok: Int(max(sqlite3_column_int64(s, okCol), 0)),
            sumDelayMs: max(sqlite3_column_int64(s, sumCol), 0),
            minDelayMs: minVal > 0 ? minVal : nil,
            maxDelayMs: maxVal > 0 ? maxVal : nil
        )
    }
}
