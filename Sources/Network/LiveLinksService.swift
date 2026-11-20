//
//  LiveLinksService.swift
//  Zest
//
//  链路采样服务：只在网络窗口进程运行，固定 2 秒，累计从窗口打开起算，不落盘。
//  每次循环重新读配置：读不到配置就不发请求。
//

import Foundation

enum LiveLinksStatus: Equatable {
    case starting, available, notRunning, configMissing, authFailed, decodeFailed
}

@MainActor
final class LiveLinksService: ObservableObject {
    @Published private(set) var status = LiveLinksStatus.starting
    @Published private(set) var ledger = TrafficLedger()
    let startedAt = Date()
    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: UInt64(NetworkMonitor.foregroundInterval) * 1_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func tick() async {
        guard let client = BettboxClient.load() else { status = .configMissing; return }
        let result = await client.fetch()
        switch result {
        case .available(let payload):
            ledger.ingest(payload, at: Date())
            status = .available
        case .notRunning: status = .notRunning
        case .configMissing: status = .configMissing
        case .authFailed: status = .authFailed
        case .decodeFailed: status = .decodeFailed
        }
    }
}
