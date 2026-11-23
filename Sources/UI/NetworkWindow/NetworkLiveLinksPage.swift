//
//  NetworkLiveLinksPage.swift
//  Zest
//

import Charts
import SwiftUI

struct NetworkLiveLinksPage: View {
    @ObservedObject var service: LiveLinksService
    @ObservedObject var history: LinkHistoryModel
    @ObservedObject var settings: AppSettings
    @State private var range = TotalsRange.today
    @State private var rule: String?
    @State private var filter = LinkFilter()

    var body: some View {
        let snap = history.snapshot
        let live = service.ledger.links.filter { l in
            (rule == nil || l.rule == rule) && filter.matches(rule: l.rule, exit: l.exit, app: l.app, host: l.host)
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                PageHeader(title: L10n.text("tab.links", defaultValue: "链路"),
                           subtitle: String(format: L10n.text("%lld 条当前链路"), Int64(live.count)))
                HStack(spacing: 4) {
                    ForEach(TotalsRange.allCases) { r in
                        ChipButton(title: title(r), count: nil, selected: range == r) { range = r }
                    }
                    if let rule {
                        ChipButton(title: String(format: L10n.text("规则：%@"), rule), count: nil, selected: true) { self.rule = nil }
                            .help(L10n.text("显示全部规则"))
                    }
                    Spacer()
                }
                HStack(spacing: 8) {
                    TextField(L10n.text("links.search", defaultValue: "搜索域名、规则、出口、应用"), text: $filter.search)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    Picker("", selection: $filter.mode) {
                        Text(L10n.text("links.mode.all", defaultValue: "全部")).tag(LinkFilter.Mode.all)
                        Text(L10n.text("links.mode.proxy", defaultValue: "仅代理")).tag(LinkFilter.Mode.proxy)
                        Text(L10n.text("links.mode.direct", defaultValue: "仅直连")).tag(LinkFilter.Mode.direct)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 220)
                    Spacer()
                    Button { LinkExport.run(range: range, rule: rule, filter: filter) } label: {
                        Label(L10n.text("links.export", defaultValue: "导出 CSV"), systemImage: "square.and.arrow.up")
                    }
                }
                if filter.hasSearch {
                    Text(L10n.text("links.search.note", defaultValue: "搜索按域名统计只覆盖最近 30 天：超过 30 天的日期无法按域名搜索，小时柱图也只按规则、出口、应用匹配。"))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if let reason = reason {
                    Card {
                        Label(reason, systemImage: "exclamationmark.triangle").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.heat)
                    }
                    .frame(maxHeight: 60)
                }
                HStack(spacing: 10) {
                    KPI(title: L10n.text("累计"), value: Fmt.bytes(Double(snap.total.down + snap.total.up)))
                    KPI(title: L10n.text("下载"), value: Fmt.bytes(Double(snap.total.down)))
                    KPI(title: L10n.text("上传"), value: Fmt.bytes(Double(snap.total.up)))
                    KPI(title: L10n.text("实时速率"), value: "↓ \(Fmt.rate(live.reduce(0) { $0 + $1.downRate }))",
                        sub: "↑ \(Fmt.rate(live.reduce(0) { $0 + $1.upRate }))")
                }
                HStack(spacing: 10) {
                    Card {
                        CardHeader(symbol: "clock", title: L10n.text("按小时（最近 24 小时）"), tint: Palette.cpu)
                        LinkBarChart(bars: snap.hourly, labelEvery: 6) { String(format: "%02d", $0 % 100) }.frame(height: 110)
                    }
                    Card {
                        CardHeader(symbol: "calendar", title: L10n.text("按天"), tint: Palette.cpu)
                        LinkBarChart(bars: snap.daily, labelEvery: max(1, snap.daily.count / 7)) { String($0 % 100) }.frame(height: 110)
                    }
                }
                Table(live) {
                    TableColumn(L10n.text("域名")) { l in Text(dash(l.host)).lineLimit(1).truncationMode(.middle) }
                        .width(min: 100, ideal: 160)
                    TableColumn(L10n.text("目标 IP")) { l in Text(dash(l.destinationIP)).font(.system(size: 11, design: .monospaced)).lineLimit(1) }
                        .width(min: 90, ideal: 120)
                    TableColumn(L10n.text("端口")) { l in Text(dash(l.port)).monospacedDigit() }
                        .width(46)
                    TableColumn(L10n.text("connections.column.app", defaultValue: "应用")) { l in Text(dash(l.app)).lineLimit(1) }
                        .width(min: 70, ideal: 100)
                    TableColumn(L10n.text("命中规则")) { l in Text(dash(l.rule)).lineLimit(1).truncationMode(.middle) }
                        .width(min: 80, ideal: 120)
                    TableColumn(L10n.text("策略链")) { l in
                        Text(l.chain.isEmpty ? "—" : l.chain.joined(separator: " → ")).lineLimit(1).truncationMode(.middle)
                            .help(l.chain.joined(separator: " → "))
                    }
                    .width(min: 100, ideal: 160)
                    TableColumn(L10n.text("出口")) { l in Text(dash(l.exit)).lineLimit(1) }
                        .width(min: 70, ideal: 100)
                    TableColumn(L10n.text("下行速率")) { l in Text(Fmt.rate(l.downRate)).monospacedDigit() }
                        .width(80)
                    TableColumn(L10n.text("上行速率")) { l in Text(Fmt.rate(l.upRate)).monospacedDigit() }
                        .width(80)
                }
                .font(.system(size: 11.5))
                .frame(height: 220)
                HStack(alignment: .top, spacing: 10) {
                    groupCard(L10n.text("按规则"), symbol: "list.bullet.rectangle", rows: snap.rules, selectable: true)
                    groupCard(L10n.text("按出口"), symbol: "arrow.up.right.square", rows: snap.exits)
                    groupCard(L10n.text("按应用"), symbol: "square.grid.2x2", rows: snap.apps)
                    groupCard(L10n.text("按域名"), symbol: "globe", rows: snap.domains)
                }
                .frame(height: 190)
                Card {
                    CardHeader(symbol: "questionmark.circle", title: L10n.text("未归属"), tint: Palette.heat)
                    row(L10n.text("总量差额"), snap.unattributed)
                }
                .frame(height: 60)
                Text(L10n.text("点选一条规则，只统计该规则。域名记录保留 30 天，规则、出口、应用的日汇总永久保留。总量取客户端自报值，各行之和与总量的差额记为“未归属”。"))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(20)
        }
        .id(settings.appLanguage)
        .onAppear { history.update(range: range, rule: rule, filter: filter); history.start() }
        .onDisappear { history.stop() }
        .onChange(of: range) { history.update(range: $0, rule: rule, filter: filter) }
        .onChange(of: rule) { history.update(range: range, rule: $0, filter: filter) }
        .onChange(of: filter) { history.update(range: range, rule: rule, filter: $0) }
    }

    private func title(_ r: TotalsRange) -> String {
        switch r {
        case .today: return L10n.text("今日")
        case .yesterday: return L10n.text("昨日")
        case .last7Days: return L10n.text("7 天")
        case .thisMonth: return L10n.text("本月")
        }
    }

    private var reason: String? {
        let name = BettboxClient.currentDisplayName()
        switch service.status {
        case .available: return nil
        case .starting: return String(format: L10n.text("nodes.client.connecting", defaultValue: "正在连接 %@…"), name)
        case .notRunning: return String(format: L10n.text("nodes.client.notRunning", defaultValue: "%@ 未运行，或控制器无法连接"), name)
        case .configMissing: return String(format: L10n.text("links.client.configMissing", defaultValue: "找不到 %@ 配置，未读取链路"), name)
        case .nonLocalController: return String(format: L10n.text("nodes.client.nonLocal", defaultValue: "%@ 控制器不是本机地址，为保护 secret 不连接"), name)
        case .authFailed: return String(format: L10n.text("nodes.client.authFailed", defaultValue: "%@ 控制器认证失败，请检查配置里的 secret"), name)
        case .decodeFailed: return String(format: L10n.text("links.client.decodeFailed", defaultValue: "无法解析 %@ 返回的连接数据"), name)
        }
    }

    private func dash(_ s: String) -> String { s.isEmpty ? "—" : s }

    /// 每卡取累计最大的前 8 行；规则卡可点选。
    private func groupCard(_ title: String, symbol: String, rows: [LinkGroup], selectable: Bool = false) -> some View {
        Card {
            CardHeader(symbol: symbol, title: title, tint: Palette.cpu)
            ForEach(rows.prefix(8)) { g in
                let line = row(g.name.isEmpty ? "—" : g.name, g.traffic)
                if selectable {
                    Button { rule = (rule == g.name) ? nil : g.name } label: { line }
                        .buttonStyle(.plain)
                        .background(rule == g.name ? Color.accentColor.opacity(0.15) : .clear)
                } else {
                    line
                }
            }
        }
    }

    private func row(_ name: String, _ t: LedgerTraffic) -> some View {
        HStack(spacing: 6) {
            Text(name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Text("↓ \(Fmt.bytes(Double(t.down)))").foregroundStyle(Palette.download)
            Text("↑ \(Fmt.bytes(Double(t.up)))").foregroundStyle(Palette.upload)
        }
        .font(.system(size: 11).monospacedDigit())
    }
}

/// 下行、上行堆叠柱图；横轴每 labelEvery 根标一次。
private struct LinkBarChart: View {
    var bars: [LinkBar]
    var labelEvery: Int
    var label: (Int) -> String

    var body: some View {
        Chart {
            ForEach(Array(bars.enumerated()), id: \.offset) { i, b in
                BarMark(x: .value(L10n.text("时间"), i), y: .value(L10n.text("流量"), b.traffic.down))
                    .foregroundStyle(Palette.download)
                BarMark(x: .value(L10n.text("时间"), i), y: .value(L10n.text("流量"), b.traffic.up))
                    .foregroundStyle(Palette.upload)
            }
        }
        .chartXAxis {
            AxisMarks(values: Array(stride(from: 0, to: max(bars.count, 1), by: max(labelEvery, 1)))) { v in
                AxisValueLabel {
                    if let i = v.as(Int.self), bars.indices.contains(i) { Text(label(bars[i].key)).font(.system(size: 9)) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { v in
                AxisGridLine()
                AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.compactBytes(d)).font(.system(size: 9)) } }
            }
        }
    }
}
