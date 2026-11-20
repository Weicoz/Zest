//
//  FlowcatImportSection.swift
//  Zest
//
//  设置窗口里的「从流量喵 Plus 导入」按钮与导入报告。
//

import SwiftUI

struct FlowcatImportSection: View {
    @ObservedObject var network: NetworkMonitor
    @State private var running = false
    @State private var report: FlowcatImportReport?

    var body: some View {
        Section {
            HStack {
                Text(L10n.text("从流量喵 Plus 导入"))
                Spacer()
                Button(L10n.text("导入…")) {
                    running = true
                    network.importFlowcat { result in report = result; running = false }
                }
                .disabled(running)
            }
            Text(L10n.text("只读流量喵 Plus 的数据目录，导入每日整机总量、应用流量、链路汇总与磁盘读写；同一日期同一类别会被覆盖，重复导入不会累加。小时数据、域名与写入提醒不导入。"))
                .font(.caption).foregroundStyle(.secondary)
            if let report {
                Text(FlowcatImportText.summary(report)).font(.caption).textSelection(.enabled)
            }
        }
    }
}

enum FlowcatImportText {
    static func name(_ c: FlowcatCategory) -> String {
        switch c {
        case .physical: return L10n.text("整机总量")
        case .apps: return L10n.text("应用流量")
        case .links: return L10n.text("链路汇总")
        case .disk: return L10n.text("磁盘读写")
        }
    }

    static func failure(_ f: FlowcatImportFailure) -> String {
        switch f {
        case .directoryMissing: return L10n.text("找不到流量喵 Plus 的数据目录，未导入任何数据。")
        case .fileCorrupt(let file): return String(format: L10n.text("文件 %@ 已损坏，未导入任何数据，已有数据不变。"), file)
        case .writeFailed: return L10n.text("写入历史库失败，已整体回滚，已有数据不变。")
        case .notPrimary: return L10n.text("只能在菜单栏主进程导入，未导入任何数据。")
        case .storeUnavailable: return L10n.text("历史库不可用，未导入任何数据。")
        }
    }

    static func summary(_ r: FlowcatImportReport) -> String {
        if let f = r.failure { return L10n.text("导入失败：") + failure(f) }
        var lines = [L10n.text("导入完成")]
        for c in FlowcatCategory.allCases {
            guard let n = r.days[c] else { continue }
            lines.append(String(format: L10n.text("%@：%lld 天"), name(c), n))
        }
        for s in r.skipped {
            switch s.reason {
            case .fileMissing:
                lines.append(String(format: L10n.text("跳过 %@：找不到 %@"), name(s.category), s.category.fileName))
            case .missingField:
                lines.append(String(format: L10n.text("跳过 %@ 日期 %@：缺少该字段"), name(s.category), s.day))
            case .emptyPath:
                lines.append(String(format: L10n.text("跳过 %@ 日期 %@ 中路径为空的记录"), name(s.category), s.day))
            case .badDate:
                lines.append(String(format: L10n.text("跳过 %@ 日期 %@：无法识别的日期"), name(s.category), s.day))
            }
        }
        return lines.joined(separator: "\n")
    }
}
