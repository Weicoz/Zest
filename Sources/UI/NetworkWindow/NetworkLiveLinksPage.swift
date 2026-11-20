//
//  NetworkLiveLinksPage.swift
//  Zest
//

import SwiftUI

struct NetworkLiveLinksPage: View {
    @ObservedObject var service: LiveLinksService
    @ObservedObject var settings: AppSettings

    var body: some View {
        let ledger = service.ledger
        VStack(alignment: .leading, spacing: 10) {
            PageHeader(title: L10n.text("tab.links", defaultValue: "链路"),
                       subtitle: String(format: L10n.text("%lld 条当前链路 · 累计为本窗口打开以来"), Int64(ledger.links.count)))
            if let reason = reason {
                Card {
                    Label(reason, systemImage: "exclamationmark.triangle").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.heat)
                }
                .frame(maxHeight: 60)
            }
            Table(ledger.links) {
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
            HStack(alignment: .top, spacing: 10) {
                totalsCard(L10n.text("按规则"), symbol: "list.bullet.rectangle", rows: ledger.byRule)
                totalsCard(L10n.text("按出口"), symbol: "arrow.up.right.square", rows: ledger.byExit)
                totalsCard(L10n.text("按应用"), symbol: "square.grid.2x2", rows: ledger.byApp)
                Card {
                    CardHeader(symbol: "questionmark.circle", title: L10n.text("未归属"), tint: Palette.heat)
                    row(L10n.text("总量差额"), ledger.unattributed)
                }
            }
            .frame(height: 190)
            Text(L10n.text("累计从本窗口打开起计算，不保存。总量取 Bettbox 自报值，各行之和与总量的差额记为“未归属”。"))
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(20)
        .id(settings.appLanguage)
    }

    private var reason: String? {
        switch service.status {
        case .available: return nil
        case .starting: return L10n.text("正在连接 Bettbox…")
        case .notRunning: return L10n.text("Bettbox 未运行，或控制器无法连接")
        case .configMissing: return L10n.text("找不到 Bettbox 配置，未读取链路")
        case .nonLocalController: return L10n.text("Bettbox 控制器不是本机地址，为保护 secret 不连接")
        case .authFailed: return L10n.text("Bettbox 控制器认证失败，请检查配置里的 secret")
        case .decodeFailed: return L10n.text("无法解析 Bettbox 返回的连接数据")
        }
    }

    private func dash(_ s: String) -> String { s.isEmpty ? "—" : s }

    /// 每卡取累计最大的前 8 行。
    private func totalsCard(_ title: String, symbol: String, rows: [String: LedgerTraffic]) -> some View {
        let top = rows.sorted { $0.value.down + $0.value.up > $1.value.down + $1.value.up }.prefix(8)
        return Card {
            CardHeader(symbol: symbol, title: title, tint: Palette.cpu)
            ForEach(Array(top), id: \.key) { row($0.key.isEmpty ? "—" : $0.key, $0.value) }
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
