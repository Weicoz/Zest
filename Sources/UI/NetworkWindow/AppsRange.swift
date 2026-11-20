//
//  AppsRange.swift
//  Zest
//
//  应用页的范围：本次与最近 24 小时来自实时与分钟明细，其余来自应用日汇总。
//  原始值兼容旧的 appsRange 存储（hour / day）。
//

import Foundation

enum AppsRange: String, CaseIterable, Identifiable {
    case hour, day, today, yesterday, last7Days, thisMonth
    var id: String { rawValue }

    /// 日汇总范围；本次与 24 小时为 nil。
    var totalsRange: TotalsRange? { TotalsRange(rawValue: rawValue) }

    var title: String {
        switch self {
        case .hour: return L10n.text("range.session", defaultValue: "本次")
        case .day: return L10n.text("24 小时")
        case .today: return L10n.text("今日")
        case .yesterday: return L10n.text("昨日")
        case .last7Days: return L10n.text("7 天")
        case .thisMonth: return L10n.text("本月")
        }
    }
}
