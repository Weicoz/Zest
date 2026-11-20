//
//  DiskLedger.swift
//  Zest
//
//  磁盘核心（纯逻辑）：输入按 PID 的累计读写快照，输出按可执行路径合并的增量。
//  PID 复用（启动时间不同）或累计值变小时按 0 起算；首次采样只作基线。
//

import Foundation

struct DiskProcessSnapshot: Equatable {
    var pid: Int32
    var path: String
    var name: String
    /// 进程启动时间（自 1970 的秒）。与 PID 一起判断 PID 是否被复用。
    var startTime: TimeInterval
    var bytesRead: UInt64
    var bytesWritten: UInt64
}

/// 按可执行路径合并后的读写增量。
struct DiskDelta: Equatable {
    var path: String
    var name: String
    var bytesRead: UInt64
    var bytesWritten: UInt64
}

/// 某范围内按可执行路径汇总的读写（来自日汇总）。
struct DiskProcessTotal: Identifiable, Equatable {
    var path: String
    var name: String
    var bytesRead: UInt64
    var bytesWritten: UInt64
    var id: String { path }
}

struct DiskAccumulator {
    private var previous: [Int32: DiskProcessSnapshot]?
    private var previousTime: TimeInterval = 0
    private var merged: [String: DiskDelta] = [:]

    var isEmpty: Bool { merged.isEmpty }

    /// 每次采样调用。首次只作基线。已知 PID 且启动时间相同：累计值变大才计差；变小按 0 起算。
    /// PID 被复用（启动时间不同）按 0 起算。上次采样之后才启动的新进程，其累计值全部发生在本区间内，按全量计入。
    mutating func ingest(_ snapshots: [DiskProcessSnapshot], at date: Date) {
        let now = date.timeIntervalSince1970
        var current: [Int32: DiskProcessSnapshot] = [:]
        for s in snapshots { current[s.pid] = s }
        defer { previous = current; previousTime = now }
        guard let previous else { return }
        for s in snapshots {
            var read: UInt64 = 0, written: UInt64 = 0
            if let old = previous[s.pid] {
                guard old.startTime == s.startTime else { continue }
                read = s.bytesRead >= old.bytesRead ? s.bytesRead - old.bytesRead : 0
                written = s.bytesWritten >= old.bytesWritten ? s.bytesWritten - old.bytesWritten : 0
            } else if s.startTime > previousTime {
                read = s.bytesRead; written = s.bytesWritten
            }
            guard read > 0 || written > 0 else { continue }
            var e = merged[s.path] ?? DiskDelta(path: s.path, name: s.name, bytesRead: 0, bytesWritten: 0)
            e.name = s.name
            e.bytesRead &+= read; e.bytesWritten &+= written
            merged[s.path] = e
        }
    }

    mutating func drain() -> [DiskDelta] {
        defer { merged = [:] }
        return merged.values.sorted { $0.path < $1.path }
    }

    /// 写库失败时放回已取出的增量，下一轮重试。
    mutating func restore(_ deltas: [DiskDelta]) {
        for d in deltas {
            var e = merged[d.path] ?? DiskDelta(path: d.path, name: d.name, bytesRead: 0, bytesWritten: 0)
            e.bytesRead &+= d.bytesRead; e.bytesWritten &+= d.bytesWritten
            merged[d.path] = e
        }
    }

    /// 清除历史后丢弃尚未写入的增量（保留基线）。
    mutating func discardPending() { merged = [:] }
}
