//
//  LinkExport.swift
//  Zest
//
//  链路页「导出 CSV」：按当前时间范围、规则与筛选，用 NSSavePanel 保存。
//

import AppKit

enum LinkExport {
    /// shortcut: 在主线程只读打开库并查询，范围至多一个月、行数有限；数据量变大时改到后台队列。
    @MainActor
    static func run(range: TotalsRange, rule: String?, filter: LinkFilter, now: Date = Date(), calendar: Calendar = .current) {
        guard let store = HistoryStore(migrate: false) else {
            return alert(L10n.text("links.export.openFailed", defaultValue: "无法读取链路历史"), "")
        }
        let days = range.dayRange(now: now, calendar: calendar)
        let cutoff = calendar.date(byAdding: .day, value: -HistoryStore.domainRetentionDays, to: now)
            .map { DayRange.key(of: $0, calendar: calendar) } ?? 0
        let rec = store.linkExportRecords(days)
        let csv = LinkCSV.document(days: rec.days, domains: rec.domains, domainCutoffDay: cutoff, filter: filter, rule: rule)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Zest-links-\(DayRange.key(of: now, calendar: calendar)).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try ("\u{FEFF}" + csv).write(to: url, atomically: true, encoding: .utf8) } catch {
            alert(L10n.text("links.export.failed", defaultValue: "无法导出链路 CSV"), error.localizedDescription)
        }
    }

    @MainActor
    private static func alert(_ title: String, _ detail: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = detail
        a.runModal()
    }
}
