//
//  DiskAlertsPage.swift
//  Zest
//
//  磁盘窗口「写入提醒」页：最近的提醒记录（时间、程序、档位、写入量）。窗口进程只读库，每 2 秒刷新。
//

import SwiftUI

@MainActor
final class DiskAlertsModel: ObservableObject {
    @Published private(set) var rows: [WriteAlertRecord] = []
    private let queue = DispatchQueue(label: "app.zest.diskalerts", qos: .utility)
    private var store: HistoryStore?
    private var task: Task<Void, Never>?

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

    private func reload() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.store == nil { self.store = HistoryStore(migrate: false) }
            guard let rows = self.store?.recentWriteAlerts() else { return }
            DispatchQueue.main.async { self.rows = rows }
        }
    }
}

struct DiskAlertsPage: View {
    @StateObject private var model = DiskAlertsModel()

    var body: some View {
        Group {
            if model.rows.isEmpty {
                Text(L10n.text("暂无写入提醒记录")).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.rows) { r in
                    HStack(spacing: 10) {
                        Text(r.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                        Text(r.name).font(.system(size: 12)).lineLimit(1).help(r.path)
                        Spacer(minLength: 12)
                        Text(r.tier == .hour ? L10n.text("每小时") : L10n.text("每天")).font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(Fmt.bytes(Double(r.bytesWritten))).font(.system(size: 11).monospacedDigit())
                    }
                }
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}
