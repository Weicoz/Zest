//
//  LinkRecorder.swift
//  Zest
//
//  主进程的链路采样：随 NetworkMonitor 的节奏（后台 8 秒、窗口可见 2 秒）读 Bettbox，
//  把账本增量写入历史存储。读不到配置不轮询。除 poll 的网络等待外，状态只在传入的串行队列上访问。
//  secret 只在 BettboxClient 内存里，不进库、日志与文件。
//

import Foundation

final class LinkRecorder: @unchecked Sendable {
    private let queue: DispatchQueue
    private let calendar: Calendar
    private var ledger = TrafficLedger()
    private var pending = LedgerDelta()
    private var inFlight = false
    /// 清除历史时加一；代次不符的在途结果丢弃，不写回清除前的增量。
    private var generation = 0

    init(queue: DispatchQueue, calendar: Calendar = .current) {
        self.queue = queue
        self.calendar = calendar
    }

    /// 在 queue 上调用。上一次请求未返回时跳过本轮。
    func poll(store: HistoryStore?) {
        guard store != nil, !inFlight else { return }
        guard case .success(let client) = BettboxClient.load() else { return ledger.interrupt() }
        inFlight = true
        let gen = generation
        Task { [self] in
            let result = await client.fetch()
            queue.async { self.handle(result, store, gen) }
        }
    }

    private func handle(_ result: BettboxResult, _ store: HistoryStore?, _ gen: Int) {
        inFlight = false
        guard gen == generation else { return ledger.interrupt() }   // 下一份快照只作新基线
        switch result {
        case .available(let payload): pending.merge(ledger.ingest(payload, at: Date(), calendar: calendar))
        case .cancelled: break
        default: ledger.interrupt()
        }
        flush(store)
    }

    /// 写库；失败时把增量放回待写，下一轮重试。
    func flush(_ store: HistoryStore?) {
        guard let store, !pending.isEmpty else { return }
        let batch = pending
        pending = LedgerDelta()
        if !store.addLinks(batch) {
            var back = batch
            back.merge(pending)
            pending = back
        }
    }

    /// 清除历史后丢弃尚未写入的增量（保留基线）。
    func discardPending() {
        pending = LedgerDelta()
        generation += 1
    }
}
