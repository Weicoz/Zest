//
//  LinkCSV.swift
//  Zest
//
//  链路账本 CSV：RFC 4180 转义与行构造，纯函数。不含 secret（库里本来就没有）。
//

import Foundation

/// 一条待导出的账本记录。host 为 nil 表示按规则 × 出口 × 应用粒度。
struct LinkExportRecord: Equatable {
    var day: Int
    var host: String?
    var rule: String
    var exit: String
    var app: String
    var traffic: LedgerTraffic
}

enum LinkCSV {
    /// 地址、端口、规则载荷、策略链库里未持久化，列保留、值留空。
    static let header = ["日期", "小时", "域名", "地址", "端口", "应用", "规则", "规则载荷", "策略链", "出口", "下载字节", "上传字节"]
    static let unattributedLabel = "未归属"

    /// 含逗号、双引号、换行的字段加双引号，内部引号加倍。
    static func field(_ s: String) -> String {
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func line(_ fields: [String]) -> String { fields.map(field).joined(separator: ",") }

    static func dayText(_ key: Int) -> String { String(format: "%04d-%02d-%02d", key / 10_000, key / 100 % 100, key % 100) }

    /// days：范围内全部日汇总行（含未归属）；domains：范围内域名行。
    /// 不早于 domainCutoffDay 的日期用域名行，更早的日期用日汇总行（域名留空）；未归属行始终取自日汇总。
    static func document(days: [LinkExportRecord], domains: [LinkExportRecord], domainCutoffDay: Int,
                         filter: LinkFilter, rule: String?) -> String {
        var rows = days.filter { $0.day < domainCutoffDay || $0.rule == LinkKey.unattributed }
        rows += domains.filter { $0.day >= domainCutoffDay }
        rows = rows.filter {
            (rule == nil || $0.rule == rule) && filter.matches(rule: $0.rule, exit: $0.exit, app: $0.app, host: $0.host)
        }
        rows.sort { ($0.day, $0.host ?? "", $0.rule, $0.exit, $0.app) < ($1.day, $1.host ?? "", $1.rule, $1.exit, $1.app) }
        let body = rows.map { r in
            line([dayText(r.day), "", r.host ?? "", "", "", r.app, r.rule == LinkKey.unattributed ? unattributedLabel : r.rule,
                  "", "", r.exit, String(r.traffic.down), String(r.traffic.up)])
        }
        return ([line(header)] + body).joined(separator: "\r\n") + "\r\n"
    }
}
