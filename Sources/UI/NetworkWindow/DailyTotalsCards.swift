//
//  DailyTotalsCards.swift
//  Zest
//
//  总览页的整机总量卡片：今日、昨日、7 天、本月（来自日汇总，主进程写入）。
//

import SwiftUI

struct DailyTotalsCards: View {
    var totals: [TotalsRange: InterfaceCounters]

    private func title(_ r: TotalsRange) -> String {
        switch r {
        case .today: return L10n.text("今日")
        case .yesterday: return L10n.text("昨日")
        case .last7Days: return L10n.text("7 天")
        case .thisMonth: return L10n.text("本月")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text("整机总量（物理网卡，含局域网与协议开销；永久保留）"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                ForEach(TotalsRange.allCases) { r in
                    let c = totals[r] ?? InterfaceCounters(bytesIn: 0, bytesOut: 0)
                    KPI(title: title(r), value: Fmt.bytes(Double(c.bytesIn &+ c.bytesOut)),
                        sub: "↓\(Fmt.bytes(Double(c.bytesIn))) ↑\(Fmt.bytes(Double(c.bytesOut)))")
                }
            }
        }
    }
}
