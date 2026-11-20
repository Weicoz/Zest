//
//  LinkHistory.swift
//  Zest
//
//  链路账本的持久化类型：增量（账本核心输出）、查询行与页面快照。纯数据，不读库。
//  口径见 docs/adr/0001-ledger-totals-from-bettbox.md。
//

import Foundation

/// 未归属行在库里的保留键（规则列）。控制字符不会出现在真实规则名里；界面单列显示，不与规则混排。
enum LinkKey {
    static let unattributed = "\u{1F}unattributed"
}

extension DayRange {
    /// 日期小时键 yyyyMMddHH，按大小即按时间排序。
    static func hourKey(of date: Date, calendar: Calendar) -> Int {
        key(of: date, calendar: calendar) * 100 + (calendar.dateComponents([.hour], from: date).hour ?? 0)
    }

    /// 范围内每个自然日的日键（含两端）。
    func days(calendar: Calendar) -> [Int] {
        func date(_ k: Int) -> Date? { calendar.date(from: DateComponents(year: k / 10_000, month: k / 100 % 100, day: k % 100)) }
        guard var d = date(from) else { return [] }
        var result: [Int] = []
        while DayRange.key(of: d, calendar: calendar) <= to, result.count < 400 {
            result.append(DayRange.key(of: d, calendar: calendar))
            guard let next = calendar.date(byAdding: .day, value: 1, to: d) else { break }
            d = next
        }
        return result
    }
}

/// 账本一轮（或多轮合并）的增量。
struct LedgerDelta: Equatable {
    struct Route: Hashable { var day: Int; var rule: String; var exit: String; var app: String }
    struct Domain: Hashable { var day: Int; var host: String; var rule: String; var exit: String; var app: String }
    struct Hour: Hashable { var hour: Int; var rule: String; var exit: String; var app: String }

    var routes: [Route: LedgerTraffic] = [:]
    var domains: [Domain: LedgerTraffic] = [:]
    var hours: [Hour: LedgerTraffic] = [:]
    /// 每日未归属（日键 → 增量）与每小时未归属。
    var unattributed: [Int: LedgerTraffic] = [:]
    var unattributedHours: [Int: LedgerTraffic] = [:]

    var isEmpty: Bool { routes.isEmpty && domains.isEmpty && hours.isEmpty && unattributed.isEmpty && unattributedHours.isEmpty }

    mutating func merge(_ o: LedgerDelta) {
        for (k, v) in o.routes { routes[k, default: LedgerTraffic()].add(v.down, v.up) }
        for (k, v) in o.domains { domains[k, default: LedgerTraffic()].add(v.down, v.up) }
        for (k, v) in o.hours { hours[k, default: LedgerTraffic()].add(v.down, v.up) }
        for (k, v) in o.unattributed { unattributed[k, default: LedgerTraffic()].add(v.down, v.up) }
        for (k, v) in o.unattributedHours { unattributedHours[k, default: LedgerTraffic()].add(v.down, v.up) }
    }
}

struct LinkGroup: Identifiable, Equatable {
    var name: String
    var traffic: LedgerTraffic
    var id: String { name }
    var total: Int64 { traffic.down + traffic.up }
}

struct LinkBar: Identifiable, Equatable {
    /// 日键或小时键。
    var key: Int
    var traffic: LedgerTraffic
    var id: Int { key }
}

/// 链路页一次查询的结果：规则、出口、应用按选中规则过滤；规则列表始终是全部规则，供切换。
struct LinkSnapshot: Equatable {
    var rules: [LinkGroup] = []
    var exits: [LinkGroup] = []
    var apps: [LinkGroup] = []
    var domains: [LinkGroup] = []
    /// 范围内未归属（选中规则时为 0）。
    var unattributed = LedgerTraffic()
    var total = LedgerTraffic()
    var hourly: [LinkBar] = []
    var daily: [LinkBar] = []

    static func groups(_ rows: [(name: String, traffic: LedgerTraffic)]) -> [LinkGroup] {
        var m: [String: LedgerTraffic] = [:]
        for r in rows { m[r.name, default: LedgerTraffic()].add(r.traffic.down, r.traffic.up) }
        return m.map { LinkGroup(name: $0.key, traffic: $0.value) }.sorted { $0.total > $1.total || ($0.total == $1.total && $0.name < $1.name) }
    }
}
