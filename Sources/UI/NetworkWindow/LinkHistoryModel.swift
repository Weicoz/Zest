//
//  LinkHistoryModel.swift
//  Zest
//
//  链路页的历史读取：窗口进程只读库（migrate: false），范围或规则变化时立即刷新，其余每 4 秒刷新。
//

import Foundation

@MainActor
final class LinkHistoryModel: ObservableObject {
    @Published private(set) var snapshot = LinkSnapshot()
    private let queue = DispatchQueue(label: "app.zest.linkhistory", qos: .utility)
    private var store: HistoryStore?
    private var task: Task<Void, Never>?
    private var range = TotalsRange.today
    private var rule: String?
    private var filter = LinkFilter()
    /// 范围或规则变化后，丢弃旧请求的结果。
    private var serial = 0

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.reload()
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func update(range: TotalsRange, rule: String?, filter: LinkFilter = LinkFilter()) {
        self.range = range
        self.rule = rule
        self.filter = filter
        serial += 1
        reload()
    }

    private func reload() {
        let (range, rule, filter, id) = (range, rule, filter, serial)
        queue.async { [weak self] in
            guard let self else { return }
            if self.store == nil { self.store = HistoryStore(migrate: false) }
            guard let snap = self.store?.linkSnapshot(range, rule: rule, filter: filter) else { return }
            DispatchQueue.main.async { if id == self.serial { self.snapshot = snap } }
        }
    }
}
