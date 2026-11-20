//
//  FlowcatImporter.swift
//  Zest
//
//  从流量喵 Plus 的数据目录导入每日汇总（整机、应用、链路、磁盘）。只读源文件；
//  先全部解析、再在一个事务里按「日期 × 类别」先删后写，任一文件损坏或写库失败整体回滚。
//  字段映射与依据见 .scratch/zest-plus/issues/09-flowcat-import.md 的「偏差」节。
//

import Foundation
import SQLite3

enum FlowcatCategory: String, CaseIterable {
    case physical, apps, links, disk
    var fileName: String {
        switch self {
        case .physical, .apps: return "ledger.json"
        case .links: return "connections.json"
        case .disk: return "disk-ledger.json"
        }
    }
}

enum FlowcatSkipReason: Equatable {
    case fileMissing
    case badDate
}

enum FlowcatImportFailure: Error, Equatable {
    case directoryMissing
    case fileCorrupt(String)
    case writeFailed
    case storeUnavailable
}

struct FlowcatImportReport: Equatable {
    struct Skip: Equatable {
        var category: FlowcatCategory
        /// 文件缺失时为空；日期无法识别时为原始键。
        var day: String
        var reason: FlowcatSkipReason
    }
    var days: [FlowcatCategory: Int] = [:]
    var skipped: [Skip] = []
    var failure: FlowcatImportFailure?
}

enum FlowcatImporter {
    static var defaultDirectory: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())).appendingPathComponent("流量账本Plus", isDirectory: true)
    }

    // MARK: 流量喵 JSON 结构（只列需要的键；缺键按空值，类型不符视为损坏）

    private struct Bytes: Decodable {
        var received: UInt64?, sent: UInt64?
    }
    private struct LedgerDay: Decodable {
        var physical: Bytes?
        var processes: [String: Bytes]?
    }
    private struct Ledger: Decodable {
        var days: [String: LedgerDay]
        var processPaths: [String: String]?
    }
    private struct ProxyBytes: Decodable { var download: UInt64?, upload: UInt64? }
    private struct Route: Decodable {
        var rule: String?, rulePayload: String?
        var chains: [String]?
        var bytes: ProxyBytes?
        var processes: [String]?
    }
    private struct ProxyDay: Decodable { var routes: [String: Route]? }
    private struct Connections: Decodable { var days: [String: ProxyDay] }
    private struct DiskBytes: Decodable { var read: UInt64?, written: UInt64? }
    private struct DiskProcess: Decodable { var name: String?, path: String?, bytes: DiskBytes? }
    private struct DiskDay: Decodable { var processes: [String: DiskProcess]? }
    private struct DiskLedger: Decodable { var days: [String: DiskDay] }

    // MARK: 解析结果

    private typealias Pair = (a: Int64, b: Int64)
    private struct Parsed {
        var physical: [Int: Pair] = [:]
        var apps: [Int: [String: Pair]] = [:]
        var meta: [String: AppMeta] = [:]
        var links: [Int: [[String]: Pair]] = [:]
        var disk: [Int: [String: (name: String, io: Pair)]] = [:]
    }

    private static func clamp(_ v: UInt64?) -> Int64 { Int64(clamping: v ?? 0) }
    private static func add(_ p: inout Pair, _ a: Int64, _ b: Int64) {
        p.a = p.a.addingReportingOverflow(a).overflow ? .max : p.a + a
        p.b = p.b.addingReportingOverflow(b).overflow ? .max : p.b + b
    }

    /// 键为 yyyy-MM-dd，返回 yyyyMMdd；无法识别返回 nil。
    static func dayKey(_ s: String) -> Int? {
        let p = s.split(separator: "-", omittingEmptySubsequences: false)
        guard p.count == 3, p[0].count == 4, p[1].count == 2, p[2].count == 2,
              let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]), (1...12).contains(m), (1...31).contains(d) else { return nil }
        return y * 10_000 + m * 100 + d
    }

    /// 应用键：进程路径在 .app 内则用最外层 .app 路径（与 Zest 采集一致），否则用进程名。
    private static func appKey(name: String, path: String?) -> (key: String, meta: AppMeta) {
        let bundle = ProcessOwners.outermostApp(path: path)
        let kind = ProcessOwners.kind(bundlePath: bundle, executablePath: path)
        if let bundle {
            return (bundle, AppMeta(key: bundle, name: name, bundlePath: bundle, kind: kind))
        }
        return (name, AppMeta(key: name, name: name, bundlePath: nil, kind: kind))
    }

    // MARK: 入口

    static func run(directory: URL, store: HistoryStore?) -> FlowcatImportReport {
        var report = FlowcatImportReport()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
            report.failure = .directoryMissing
            return report
        }
        guard let store else { report.failure = .storeUnavailable; return report }
        var parsed = Parsed()
        let decoder = JSONDecoder()
        func load<T: Decodable>(_ name: String, _ type: T.Type, missing: [FlowcatCategory]) throws -> T? {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                for c in missing { report.skipped.append(.init(category: c, day: "", reason: .fileMissing)) }
                return nil
            }
            do { return try decoder.decode(T.self, from: Data(contentsOf: url)) }
            catch { throw FlowcatImportFailure.fileCorrupt(name) }
        }
        do {
            if let l = try load("ledger.json", Ledger.self, missing: [.physical, .apps]) {
                for (k, d) in l.days.sorted(by: { $0.key < $1.key }) {
                    guard let day = dayKey(k) else {
                        for c in [FlowcatCategory.physical, .apps] { report.skipped.append(.init(category: c, day: k, reason: .badDate)) }
                        continue
                    }
                    parsed.physical[day] = (clamp(d.physical?.received), clamp(d.physical?.sent))
                    var apps: [String: Pair] = [:]
                    for (name, b) in d.processes ?? [:] {
                        let (key, meta) = appKey(name: name, path: l.processPaths?[name])
                        parsed.meta[key] = parsed.meta[key] ?? meta
                        add(&apps[key, default: (0, 0)], clamp(b.received), clamp(b.sent))
                    }
                    parsed.apps[day] = apps
                }
            }
            if let c = try load("connections.json", Connections.self, missing: [.links]) {
                for (k, d) in c.days.sorted(by: { $0.key < $1.key }) {
                    guard let day = dayKey(k) else { report.skipped.append(.init(category: .links, day: k, reason: .badDate)); continue }
                    var rows: [[String]: Pair] = [:]
                    for r in (d.routes ?? [:]).values {
                        let rule = r.rule ?? ""
                        let name = (r.rulePayload ?? "").isEmpty ? rule : "\(rule): \(r.rulePayload ?? "")"
                        let first = r.chains?.first ?? ""
                        let exit = first.caseInsensitiveCompare("DIRECT") == .orderedSame ? "DIRECT" : first
                        add(&rows[[name, exit, r.processes?.first ?? ""], default: (0, 0)], clamp(r.bytes?.download), clamp(r.bytes?.upload))
                    }
                    parsed.links[day] = rows
                }
            }
            if let dl = try load("disk-ledger.json", DiskLedger.self, missing: [.disk]) {
                for (k, d) in dl.days.sorted(by: { $0.key < $1.key }) {
                    guard let day = dayKey(k) else { report.skipped.append(.init(category: .disk, day: k, reason: .badDate)); continue }
                    var rows: [String: (name: String, io: Pair)] = [:]
                    for p in (d.processes ?? [:]).values {
                        let path = p.path ?? ""
                        var e = rows[path] ?? (p.name ?? (path as NSString).lastPathComponent, (0, 0))
                        add(&e.io, clamp(p.bytes?.read), clamp(p.bytes?.written))
                        rows[path] = e
                    }
                    parsed.disk[day] = rows
                }
            }
        } catch let f as FlowcatImportFailure {
            report.failure = f
            return report
        } catch { report.failure = .writeFailed; return report }

        guard store.writeFlowcat(parsed.physical, parsed.apps, parsed.meta, parsed.links, parsed.disk) else {
            report.failure = .writeFailed
            return report
        }
        let missing = Set(report.skipped.filter { $0.reason == .fileMissing }.map(\.category))
        let counts: [FlowcatCategory: Int] = [.physical: parsed.physical.count, .apps: parsed.apps.count,
                                              .links: parsed.links.count, .disk: parsed.disk.count]
        report.days = counts.filter { !missing.contains($0.key) }
        return report
    }
}

private extension HistoryStore {
    /// 单事务：每个出现的日期先删该类别旧行再写入。失败整体回滚。
    func writeFlowcat(_ physical: [Int: (a: Int64, b: Int64)], _ apps: [Int: [String: (a: Int64, b: Int64)]],
                      _ meta: [String: AppMeta], _ links: [Int: [[String]: (a: Int64, b: Int64)]],
                      _ disk: [Int: [String: (name: String, io: (a: Int64, b: Int64))]]) -> Bool {
        guard exec("BEGIN IMMEDIATE") else { return false }
        var ok = true
        func run(_ sql: String, _ bind: (OpaquePointer) -> Void) {
            guard ok, let s = prepare(sql) else { ok = false; return }
            bind(s)
            if sqlite3_step(s) != SQLITE_DONE { ok = false }
            sqlite3_finalize(s)
        }
        func day(_ s: OpaquePointer, _ d: Int) { sqlite3_bind_int64(s, 1, Int64(d)) }
        for (d, p) in physical {
            run("DELETE FROM daily_physical WHERE day = ?") { day($0, d) }
            run("INSERT INTO daily_physical(day, bytes_in, bytes_out) VALUES(?,?,?)") {
                day($0, d); sqlite3_bind_int64($0, 2, p.a); sqlite3_bind_int64($0, 3, p.b)
            }
        }
        for (d, rows) in apps {
            run("DELETE FROM daily_apps WHERE day = ?") { day($0, d) }
            for (k, p) in rows {
                run("INSERT INTO daily_apps(day, app_key, bytes_in, bytes_out) VALUES(?,?,?,?)") {
                    day($0, d); bind($0, 2, k); sqlite3_bind_int64($0, 3, p.a); sqlite3_bind_int64($0, 4, p.b)
                }
            }
        }
        for m in meta.values {
            run("INSERT OR IGNORE INTO apps(app_key, name, bundle, kind) VALUES(?,?,?,?)") {
                bind($0, 1, m.key); bind($0, 2, m.name); bind($0, 3, m.bundlePath); sqlite3_bind_int($0, 4, Int32(m.kind.rawValue))
            }
        }
        for (d, rows) in links {
            run("DELETE FROM link_days WHERE day = ?") { day($0, d) }
            for (k, p) in rows {
                run("INSERT INTO link_days(day, rule, egress, app, bytes_in, bytes_out) VALUES(?,?,?,?,?,?)") {
                    day($0, d); bind($0, 2, k[0]); bind($0, 3, k[1]); bind($0, 4, k[2])
                    sqlite3_bind_int64($0, 5, p.a); sqlite3_bind_int64($0, 6, p.b)
                }
            }
        }
        for (d, rows) in disk {
            run("DELETE FROM disk_days WHERE day = ?") { day($0, d) }
            for (path, e) in rows {
                run("INSERT INTO disk_days(day, path, name, bytes_read, bytes_written) VALUES(?,?,?,?,?)") {
                    day($0, d); bind($0, 2, path); bind($0, 3, e.name)
                    sqlite3_bind_int64($0, 4, e.io.a); sqlite3_bind_int64($0, 5, e.io.b)
                }
            }
        }
        if ok, exec("COMMIT") { return true }
        exec("ROLLBACK")
        return false
    }
}
