//
//  LiveLinksService.swift
//  Zest
//
//  链路采样服务：只在网络窗口进程运行，固定 2 秒，累计从窗口打开起算，不落盘。
//  每次循环重新读配置：读不到配置就不发请求。
//

import Foundation

enum LiveLinksStatus: Equatable {
    case starting, available, notRunning, configMissing, nonLocalController, authFailed, decodeFailed
}

@MainActor
final class LiveLinksService: ObservableObject {
    @Published private(set) var status = LiveLinksStatus.starting
    @Published private(set) var ledger = TrafficLedger()
    private var task: Task<Void, Never>?
    /// stop() 后旧 tick 可能仍在 await；代次不符的结果一律丢弃。
    private var generation = 0

    func start() {
        guard task == nil else { return }
        generation += 1
        let gen = generation
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick(gen)
                try? await Task.sleep(nanoseconds: UInt64(NetworkMonitor.foregroundInterval) * 1_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        generation += 1
    }

    private func tick(_ gen: Int) async {
        let client: BettboxClient
        switch BettboxClient.load() {
        case .success(let c): client = c
        case .failure(.missing): return fail(.configMissing, gen)
        case .failure(.nonLocal): return fail(.nonLocalController, gen)
        }
        let result = await client.fetch()
        guard gen == generation else { return }
        switch result {
        case .available(let payload):
            ledger.ingest(payload, at: Date())
            status = .available
        case .cancelled: break
        case .notRunning: fail(.notRunning, gen)
        case .configMissing: fail(.configMissing, gen)
        case .nonLocalController: fail(.nonLocalController, gen)
        case .authFailed: fail(.authFailed, gen)
        case .decodeFailed: fail(.decodeFailed, gen)
        }
    }

    /// 不可用时清空当前链路与速率，累计保留；恢复后的第一份快照只作基线。
    private func fail(_ s: LiveLinksStatus, _ gen: Int) {
        guard gen == generation else { return }
        ledger.interrupt()
        status = s
    }
}
