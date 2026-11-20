//
//  DiskIOService.swift
//  Zest
//
//  主进程的按进程磁盘读写采样：遍历进程取 proc_pid_rusage 的累计读写字节，交给 DiskAccumulator 合并后写库。
//  后台每 10 秒，磁盘窗口可见时每 2 秒。只有菜单栏主进程运行；磁盘窗口进程只读库。
//

import Foundation

final class DiskIOService: @unchecked Sendable {
    static let backgroundInterval = 10
    static let foregroundInterval = 2

    private let queue = DispatchQueue(label: "app.zest.disk", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var store: HistoryStore?
    private var accumulator = DiskAccumulator()
    private var windowVisible = false
    private var pidBuffer = [pid_t](repeating: 0, count: 2048)
    /// 同一 PID 的路径与名称不变，启动时间相同即可复用，免得每轮重复取路径。
    private var identity: [pid_t: (start: TimeInterval, path: String, name: String)] = [:]

    func start() {
        queue.async { [self] in
            if store == nil { store = HistoryStore() }
            schedule()
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }

    /// 磁盘窗口进程启动或退出时调用，切换采样节奏。
    func setWindowVisible(_ visible: Bool) {
        queue.async { [self] in
            guard visible != windowVisible else { return }
            windowVisible = visible
            if timer != nil { schedule() }
        }
    }

    /// 清除历史：丢弃待写增量并清空磁盘表，与写库在同一队列上串行。
    func clear() {
        queue.async { [self] in
            accumulator.discardPending()
            store?.clearDisk()
        }
    }

    /// 退出前同步写入待写增量。
    func flushSync() {
        queue.sync { flush() }
    }

    private func schedule() {
        timer?.cancel()
        let seconds = windowVisible ? DiskIOService.foregroundInterval : DiskIOService.backgroundInterval
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .seconds(seconds), leeway: .milliseconds(seconds * 100))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    private func tick() {
        accumulator.ingest(snapshots(), at: Date())
        flush()
    }

    private func flush() {
        guard let store, !accumulator.isEmpty else { return }
        let batch = accumulator.drain()
        if !store.addDisk(batch, at: Date()) { accumulator.restore(batch) }
    }

    private func snapshots() -> [DiskProcessSnapshot] {
        var result: [DiskProcessSnapshot] = []
        var alive: [pid_t: (start: TimeInterval, path: String, name: String)] = [:]
        for pid in ProcessOwners.allPIDs(buffer: &pidBuffer) {
            var info = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) == 0 }
            }
            guard ok else { continue }
            var bsd = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size)
            else { continue }
            let start = TimeInterval(bsd.pbi_start_tvsec) + TimeInterval(bsd.pbi_start_tvusec) / 1_000_000
            var id = identity[pid]
            if id == nil || id?.start != start {
                let name = ProcessOwners.name(pid)
                id = (start, ProcessOwners.path(pid) ?? name, name)
            }
            alive[pid] = id
            result.append(DiskProcessSnapshot(pid: pid, path: id!.path, name: id!.name, startTime: start,
                                              bytesRead: info.ri_diskio_bytesread, bytesWritten: info.ri_diskio_byteswritten))
        }
        identity = alive
        return result
    }
}
