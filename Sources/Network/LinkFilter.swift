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

    /// host 为 nil 表示该行没有域名粒度（日汇总、小时数据），此时只按规则、出口、应用匹配。
    func matches(rule: String, exit: String, app: String, host: String? = nil) -> Bool {
        if rule == LinkKey.unattributed { return isEmpty }   // 未归属行只在「全部」且无搜索时显示
        switch mode {
        case .all: break
        case .proxy: if LinkFilter.isDirect(exit) { return false }
        case .direct: if !LinkFilter.isDirect(exit) { return false }
        }
        let q = trimmed
        if q.isEmpty { return true }
        return [rule, exit, app, host ?? ""].contains { $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}
