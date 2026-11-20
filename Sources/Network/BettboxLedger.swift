//
//  BettboxLedger.swift
//  Zest
//
//  链路账本核心：纯逻辑，不读文件、不联网、不落盘。口径见 docs/adr/0001-ledger-totals-from-bettbox.md。
//

import Foundation

/// Bettbox（Mihomo）`GET /connections` 里的单条连接。字段缺失时按空值解码。
struct BettboxConnection: Decodable, Equatable {
    struct Metadata: Decodable, Equatable {
        var type = ""
        var host = ""
        var destinationIP = ""
        var destinationPort = ""
        var process = ""

        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            type = (try? c.decode(String.self, forKey: .type)) ?? ""
            host = (try? c.decode(String.self, forKey: .host)) ?? ""
            destinationIP = (try? c.decode(String.self, forKey: .destinationIP)) ?? ""
            process = (try? c.decode(String.self, forKey: .process)) ?? ""
            // Mihomo 把端口写成字符串；兼容数字。
            if let s = try? c.decode(String.self, forKey: .destinationPort) { destinationPort = s }
            else if let n = try? c.decode(Int.self, forKey: .destinationPort) { destinationPort = String(n) }
        }
        private enum Keys: String, CodingKey { case type, host, destinationIP, destinationPort, process }
    }

    var id: String
    var upload: Int64
    var download: Int64
    var chains: [String]
    var rule: String
    var rulePayload: String
    var metadata: Metadata

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        upload = (try? c.decode(Int64.self, forKey: .upload)) ?? 0
        download = (try? c.decode(Int64.self, forKey: .download)) ?? 0
        chains = (try? c.decode([String].self, forKey: .chains)) ?? []
        rule = (try? c.decode(String.self, forKey: .rule)) ?? ""
        rulePayload = (try? c.decode(String.self, forKey: .rulePayload)) ?? ""
        metadata = (try? c.decode(Metadata.self, forKey: .metadata)) ?? Metadata()
    }
    private enum Keys: String, CodingKey { case id, upload, download, chains, rule, rulePayload, metadata }

    /// 出口：Mihomo 的 chains 按「实际出站在前、策略组在后」排列。
    /// 依据：本机 Bettbox 实测，`["<节点>", "<组>", "<更外层组>"]` 里 chains[0] 是真实节点，
    /// 末项是最外层策略组（用 /proxies 核对，末项 type 为 Selector）；直连为 `["DIRECT"]` 或 `["DIRECT", "<组>"]`。
    /// 所以「流量离开的最后一跳」是 chains.first，不是数组末项。
    var exit: String {
        guard let first = chains.first else { return "" }
        return first.caseInsensitiveCompare("DIRECT") == .orderedSame ? "DIRECT" : first
    }

    /// 命中规则显示名，例如 `RuleSet: name`。
    var ruleName: String { rulePayload.isEmpty ? rule : "\(rule): \(rulePayload)" }

    var isInner: Bool { metadata.type.caseInsensitiveCompare("Inner") == .orderedSame }
}

struct BettboxPayload: Decodable, Equatable {
    var downloadTotal: Int64
    var uploadTotal: Int64
    var connections: [BettboxConnection]

    private enum Keys: String, CodingKey { case downloadTotal, uploadTotal, connections }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        downloadTotal = try c.decode(Int64.self, forKey: .downloadTotal)
        uploadTotal = try c.decode(Int64.self, forKey: .uploadTotal)
        // 无连接时 Mihomo 可能给 null。
        connections = (try c.decodeIfPresent([BettboxConnection].self, forKey: .connections)) ?? []
    }
}

struct LedgerTraffic: Equatable {
    var down: Int64 = 0
    var up: Int64 = 0
    mutating func add(_ d: Int64, _ u: Int64) { down += d; up += u }
}

struct LiveLink: Identifiable, Equatable {
    var id: String
    var host: String
    var destinationIP: String
    var port: String
    var app: String
    var rule: String
    /// 从策略组到节点（与 Mihomo 控制台一致），即 chains 反序。
    var chain: [String]
    var exit: String
    var downRate: Double
    var upRate: Double
}

/// 累计从第一份快照之后算起：第一份只作基线（此前已存在的字节不属于本次）。
struct TrafficLedger {
    private var seen: [String: (down: Int64, up: Int64)] = [:]
    private var lastTotals: (down: Int64, up: Int64)?
    private var lastAt: Date?

    private(set) var byRule: [String: LedgerTraffic] = [:]
    private(set) var byExit: [String: LedgerTraffic] = [:]
    private(set) var byApp: [String: LedgerTraffic] = [:]
    private(set) var unattributed = LedgerTraffic()
    private(set) var links: [LiveLink] = []

    /// 累计变小视为计数重置，按 0 起算，即增量取当前值。
    private static func delta(_ cur: Int64, _ prev: Int64?) -> Int64 {
        guard let prev else { return cur }
        return cur >= prev ? cur - prev : cur
    }

    /// Bettbox 不可用（未运行、认证失败等）：清空当前链路与速率，累计保留；
    /// 下一份成功快照只作新基线，停机期间的增量不计入累计与未归属。
    mutating func interrupt() {
        seen = [:]
        lastTotals = nil
        lastAt = nil
        links = []
    }

    /// 返回本轮增量（按采样时刻所在本地日、小时归档），供主进程写库；窗口进程忽略返回值。
    @discardableResult
    mutating func ingest(_ payload: BettboxPayload, at: Date, calendar: Calendar = .current) -> LedgerDelta {
        var delta = LedgerDelta()
        let day = DayRange.key(of: at, calendar: calendar)
        let hour = DayRange.hourKey(of: at, calendar: calendar)
        let baseline = lastTotals == nil
        let dt = lastAt.map { at.timeIntervalSince($0) } ?? 0
        var next: [String: (down: Int64, up: Int64)] = [:]
        var sumDown: Int64 = 0, sumUp: Int64 = 0
        var rows: [LiveLink] = []
        for c in payload.connections where !c.isInner {
            let prev = seen[c.id]
            next[c.id] = (c.download, c.upload)
            let d = baseline ? 0 : Self.delta(c.download, prev?.down)
            let u = baseline ? 0 : Self.delta(c.upload, prev?.up)
            sumDown += d; sumUp += u
            if d > 0 || u > 0 {
                delta.routes[.init(day: day, rule: c.ruleName, exit: c.exit, app: c.metadata.process), default: LedgerTraffic()].add(d, u)
                delta.domains[.init(day: day, host: c.metadata.host, rule: c.ruleName, exit: c.exit, app: c.metadata.process),
                              default: LedgerTraffic()].add(d, u)
                delta.hours[.init(hour: hour, rule: c.ruleName, exit: c.exit, app: c.metadata.process), default: LedgerTraffic()].add(d, u)
            }
            byRule[c.ruleName, default: LedgerTraffic()].add(d, u)
            byExit[c.exit, default: LedgerTraffic()].add(d, u)
            byApp[c.metadata.process, default: LedgerTraffic()].add(d, u)
            rows.append(LiveLink(id: c.id, host: c.metadata.host, destinationIP: c.metadata.destinationIP,
                                 port: c.metadata.destinationPort, app: c.metadata.process, rule: c.ruleName,
                                 chain: c.chains.reversed(), exit: c.exit,
                                 downRate: dt > 0 ? Double(d) / dt : 0, upRate: dt > 0 ? Double(u) / dt : 0))
        }
        if let last = lastTotals {
            // 自报总量变小：Bettbox 重启，本轮总量增量取逐连接增量之和，未归属记 0。
            let td = payload.downloadTotal >= last.down ? payload.downloadTotal - last.down : sumDown
            let tu = payload.uploadTotal >= last.up ? payload.uploadTotal - last.up : sumUp
            let ud = max(0, td - sumDown), uu = max(0, tu - sumUp)
            unattributed.add(ud, uu)
            if ud > 0 || uu > 0 {
                delta.unattributed[day, default: LedgerTraffic()].add(ud, uu)
                delta.unattributedHours[hour, default: LedgerTraffic()].add(ud, uu)
            }
        }
        seen = next   // 已关闭连接随之清掉
        lastTotals = (payload.downloadTotal, payload.uploadTotal)
        lastAt = at
        links = rows
        return delta
    }
}
