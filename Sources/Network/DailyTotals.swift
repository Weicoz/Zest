//
//  DailyTotals.swift
//  Zest
//
//  日汇总的通用范围类型、整机总量范围预设，以及物理网卡计数的分钟累加器。
//  日界按注入日历的时区 0 点；日键为 yyyyMMdd 整数，按大小即按时间排序。
//

import Foundation

/// 闭区间日键范围 [from, to]。后续票（应用、链路、磁盘日汇总）共用。
struct DayRange: Equatable {
    var from: Int
    var to: Int

    static func key(of date: Date, calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 0) * 10_000 + (c.month ?? 0) * 100 + (c.day ?? 0)
    }
}

enum TotalsRange: String, CaseIterable, Identifiable {
    case today, yesterday, last7Days, thisMonth
    var id: String { rawValue }

    /// 今日、昨日、含今天的最近 7 个自然日、本月自然月（月初到今天）。
    func dayRange(now: Date, calendar: Calendar) -> DayRange {
        let today = calendar.startOfDay(for: now)
        func shifted(_ days: Int) -> Int {
            DayRange.key(of: calendar.date(byAdding: .day, value: days, to: today) ?? today, calendar: calendar)
        }
        switch self {
        case .today: return DayRange(from: shifted(0), to: shifted(0))
        case .yesterday: return DayRange(from: shifted(-1), to: shifted(-1))
        case .last7Days: return DayRange(from: shifted(-6), to: shifted(0))
        case .thisMonth:
            let c = calendar.dateComponents([.year, .month], from: now)
            let base = (c.year ?? 0) * 10_000 + (c.month ?? 0) * 100
            return DayRange(from: base + 1, to: shifted(0))
        }
    }
}

/// 物理网卡计数的差分累加器：主进程每次采样调用 ingest，每分钟结束时 drain 出来写库。
/// 首次采样只作基线（重启后不重复计入）；接口消失、出现或计数变小按 0 起算（见 NetworkMath.delta）。
/// 睡眠期间的差分会计入唤醒后的第一次采样，不丢也不重复。
struct PhysicalAccumulator {
    private var previous: [UInt16: InterfaceCounters]?
    private(set) var pending = InterfaceCounters(bytesIn: 0, bytesOut: 0)

    mutating func ingest(_ current: [UInt16: InterfaceCounters]) {
        defer { previous = current }
        guard let previous else { return }
        let d = NetworkMath.delta(previous: previous, current: current)
        pending.bytesIn &+= d.bytesIn
        pending.bytesOut &+= d.bytesOut
    }

    /// 写库失败时放回已取出的增量，下一分钟重试。
    mutating func restore(_ c: InterfaceCounters) {
        pending.bytesIn &+= c.bytesIn
        pending.bytesOut &+= c.bytesOut
    }

    /// 清除历史后丢弃尚未写入的增量（保留基线）。
    mutating func discardPending() { pending = InterfaceCounters(bytesIn: 0, bytesOut: 0) }

    mutating func drain() -> InterfaceCounters {
        defer { pending = InterfaceCounters(bytesIn: 0, bytesOut: 0) }
        return pending
    }
}
