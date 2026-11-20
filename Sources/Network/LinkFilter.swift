//
//  LinkFilter.swift
//  Zest
//
//  链路页的搜索与「全部 / 仅代理 / 仅直连」筛选。纯逻辑，列表、汇总、柱图与 CSV 共用。
//

import Foundation

struct LinkFilter: Equatable {
    enum Mode: String, CaseIterable, Identifiable {
        case all, proxy, direct
        var id: String { rawValue }
    }

    var search = ""
    var mode = Mode.all

    var isEmpty: Bool { trimmed.isEmpty && mode == .all }
    private var trimmed: String { search.trimmingCharacters(in: .whitespaces) }

    /// 直连即出口为 DIRECT；其余出口都算代理。
    static func isDirect(_ exit: String) -> Bool { exit.caseInsensitiveCompare("DIRECT") == .orderedSame }

    /// 仅代理只算真实代理节点：排除 DIRECT、REJECT 系与空出口。
    static func isProxy(_ exit: String) -> Bool {
        !exit.isEmpty && !isDirect(exit) && !exit.uppercased().hasPrefix("REJECT")
    }

    var hasSearch: Bool { !trimmed.isEmpty }

    /// 按筛选与规则范围挑出要汇总的行。无搜索时用日汇总；有搜索或 domainsForRecent 时，
    /// 不早于 cutoff 的日期改用域名日记录（含域名匹配），更早的日期只有日汇总（无法按域名匹配）；未归属行始终取自日汇总。
    func pick(days: [LinkExportRecord], domains: [LinkExportRecord], cutoff: Int, rule: String?,
              domainsForRecent: Bool = false) -> [LinkExportRecord] {
        let useDomains = hasSearch || domainsForRecent
        var rows = useDomains ? days.filter { $0.day < cutoff || $0.rule == LinkKey.unattributed } : days
        if useDomains { rows += domains.filter { $0.day >= cutoff } }
        return rows.filter { (rule == nil || $0.rule == rule) && matches(rule: $0.rule, exit: $0.exit, app: $0.app, host: $0.host) }
    }

    /// host 为 nil 表示该行没有域名粒度（日汇总、小时数据），此时只按规则、出口、应用匹配。
    func matches(rule: String, exit: String, app: String, host: String? = nil) -> Bool {
        if rule == LinkKey.unattributed { return isEmpty }   // 未归属行只在「全部」且无搜索时显示
        switch mode {
        case .all: break
        case .proxy: if !LinkFilter.isProxy(exit) { return false }
        case .direct: if !LinkFilter.isDirect(exit) { return false }
        }
        let q = trimmed
        if q.isEmpty { return true }
        return [rule, exit, app, host ?? ""].contains { $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}
