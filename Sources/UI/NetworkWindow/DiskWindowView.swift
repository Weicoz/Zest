//
//  DiskWindowView.swift
//  Zest
//
//  “磁盘”窗口：写入排行、写入提醒、健康三个页签。
//  窗口进程只读库（migrate: false），范围或排序变化时立即刷新，其余每 2 秒刷新。
//

import SwiftUI

enum DiskPage: String, CaseIterable, Identifiable {
    case ranking, alerts, health
    var id: String { rawValue }

    var title: String {
        switch self {
        case .ranking: return L10n.text("写入排行")
        case .alerts: return L10n.text("写入提醒")
        case .health: return L10n.text("健康")
        }
    }
}

@MainActor
final class DiskHistoryModel: ObservableObject {
    @Published private(set) var rows: [DiskProcessTotal] = []
    private let queue = DispatchQueue(label: "app.zest.diskhistory", qos: .utility)
    private var store: HistoryStore?
    private var task: Task<Void, Never>?
    private var range = TotalsRange.today
    /// 范围变化后，丢弃旧请求的结果。
    private var serial = 0

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.reload()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func update(range: TotalsRange) {
        self.range = range
        serial += 1
        reload()
    }

    private func reload() {
        let (range, id) = (range, serial)
        queue.async { [weak self] in
            guard let self else { return }
            if self.store == nil { self.store = HistoryStore(migrate: false) }
            guard let rows = self.store?.diskTotals(range.dayRange(now: Date(), calendar: .current)) else { return }
            DispatchQueue.main.async { if id == self.serial { self.rows = rows } }
        }
    }
}

struct DiskWindowView: View {
    @ObservedObject var settings: AppSettings
    @AppStorage("diskPage") private var page = DiskPage.ranking

    var body: some View {
        VStack(spacing: 12) {
            Picker("", selection: $page) {
                ForEach(DiskPage.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)
            switch page {
            case .ranking: DiskRankingPage()
            case .alerts: DiskAlertsPage()
            case .health: DiskHealthPage()
            }
        }
        .padding(16)
        .background(Palette.panelBackground)
        .id(settings.appLanguage)
    }
}

private struct DiskRankingPage: View {
    @StateObject private var model = DiskHistoryModel()
    @State private var range = TotalsRange.today
    @State private var sortByRead = false

    private func title(_ r: TotalsRange) -> String {
        switch r {
        case .today: return L10n.text("今日")
        case .yesterday: return L10n.text("昨日")
        case .last7Days: return L10n.text("7 天")
        case .thisMonth: return L10n.text("本月")
        }
    }

    private var sorted: [DiskProcessTotal] {
        model.rows.filter { sortByRead ? $0.bytesRead > 0 : $0.bytesWritten > 0 }
            .sorted { a, b in
                let (x, y) = sortByRead ? (a.bytesRead, b.bytesRead) : (a.bytesWritten, b.bytesWritten)
                return x != y ? x > y : a.path < b.path
            }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Picker("", selection: $range) {
                    ForEach(TotalsRange.allCases) { Text(title($0)).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 260)
                Spacer()
                Picker("", selection: $sortByRead) {
                    Text(L10n.text("按写入")).tag(false)
                    Text(L10n.text("按读取")).tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 180)
            }
            let rows = sorted
            if rows.isEmpty {
                Text(L10n.text("暂无磁盘读写记录")).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let top = Double(rows.first.map { sortByRead ? $0.bytesRead : $0.bytesWritten } ?? 1)
                List(rows) { r in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(r.name).font(.system(size: 12)).lineLimit(1)
                            CapsuleBar(fraction: Double(sortByRead ? r.bytesRead : r.bytesWritten) / max(top, 1),
                                       color: sortByRead ? Palette.disk : Palette.upload, height: 4)
                        }
                        Spacer(minLength: 12)
                        Text("\(L10n.text("写入")) \(Fmt.bytes(Double(r.bytesWritten)))")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(sortByRead ? .secondary : .primary)
                        Text("\(L10n.text("读取")) \(Fmt.bytes(Double(r.bytesRead)))")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(sortByRead ? .primary : .secondary)
                    }
                    .help(r.path)
                }
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .onChange(of: range) { model.update(range: $0) }
    }
}
