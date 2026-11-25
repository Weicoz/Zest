//
//  NetworkTracker.swift
//  Zest
//
//  把 nettop 采样汇总为“每个应用”的实时速率、本次累计、60 分钟历史与当前连接。
//

import Foundation

struct TrafficPoint: Equatable, Codable {
    var bytesIn: Double
    var bytesOut: Double
}

struct LiveSeedPoint: Equatable, Codable {
    var timestamp: TimeInterval
    var bytesIn: Double
    var bytesOut: Double
}

struct LiveSeedSnapshot: Equatable, Codable {
    var savedAt: TimeInterval
    var points: [LiveSeedPoint]

    /// 将主进程（后台 8s / 前台 2s）的时间戳样本重采样到窗口进程 2s 均匀网格，
    /// 相邻间隔超过 maxGapSeconds（如休眠）则填 0；快照超过 60s 视为过期返回空。
    func resampled(now: TimeInterval,
                   stepSeconds: TimeInterval = 2.0,
                   capacity: Int = NetworkTracker.liveCapacity,
                   maxGapSeconds: TimeInterval = 20.0) -> [TrafficPoint] {
        guard abs(now - savedAt) <= 60, !points.isEmpty, stepSeconds > 0, capacity > 0 else {
            return []
        }
        let minTs = now - Double(capacity) * stepSeconds - maxGapSeconds
        let maxTs = now + 5.0
        let sorted = points
            .filter { $0.timestamp >= minTs && $0.timestamp <= maxTs }
            .sorted { $0.timestamp < $1.timestamp }
        guard let first = sorted.first, let last = sorted.last else { return [] }
        if sorted.count == 1 {
            return [TrafficPoint(bytesIn: max(0, first.bytesIn), bytesOut: max(0, first.bytesOut))]
        }

        let startTs = max(first.timestamp, now - Double(capacity - 1) * stepSeconds)
        let endTs = min(now, last.timestamp)
        guard endTs >= startTs else {
            return [TrafficPoint(bytesIn: max(0, last.bytesIn), bytesOut: max(0, last.bytesOut))]
        }

        var result: [TrafficPoint] = []
        result.reserveCapacity(capacity)
        var cursor = 0
        var stepIdx = 0
        while true {
            let t = startTs + Double(stepIdx) * stepSeconds
            if t > endTs + stepSeconds * 0.001 { break }
            while cursor + 1 < sorted.count && sorted[cursor + 1].timestamp < t {
                cursor += 1
            }
            if t <= first.timestamp {
                result.append(TrafficPoint(bytesIn: max(0, first.bytesIn), bytesOut: max(0, first.bytesOut)))
            } else if cursor + 1 >= sorted.count {
                result.append(TrafficPoint(bytesIn: max(0, last.bytesIn), bytesOut: max(0, last.bytesOut)))
            } else {
                let a = sorted[cursor]
                let b = sorted[cursor + 1]
                let span = b.timestamp - a.timestamp
                if abs(t - a.timestamp) <= 1e-6 {
                    result.append(TrafficPoint(bytesIn: max(0, a.bytesIn), bytesOut: max(0, a.bytesOut)))
                } else if abs(t - b.timestamp) <= 1e-6 {
                    result.append(TrafficPoint(bytesIn: max(0, b.bytesIn), bytesOut: max(0, b.bytesOut)))
                } else if span > maxGapSeconds {
                    result.append(TrafficPoint(bytesIn: 0, bytesOut: 0))
                } else if span <= 0 {
                    result.append(TrafficPoint(bytesIn: max(0, b.bytesIn), bytesOut: max(0, b.bytesOut)))
                } else {
                    let ratio = min(max((t - a.timestamp) / span, 0), 1)
                    let inVal = max(0, a.bytesIn + (b.bytesIn - a.bytesIn) * ratio)
                    let outVal = max(0, a.bytesOut + (b.bytesOut - a.bytesOut) * ratio)
                    result.append(TrafficPoint(bytesIn: inVal, bytesOut: outVal))
                }
            }
            stepIdx += 1
        }
        if result.count > capacity {
            return Array(result.suffix(capacity))
        }
        return result
    }
}

struct FlowInfo: Identifiable, Equatable {
    var id: String               // NettopConnectionRow.key
    var appKey: String
    var appName: String
    var pid: pid_t
    var proto: NetProtocol
    var local: Endpoint?
    var remote: Endpoint?
    var state: String
    var scope: AddressScope
    var bytesIn: UInt64
    var bytesOut: UInt64
    var firstSeen: Date
    /// 公网远端的离线归属地（DB-IP Lite）。
    var geo: GeoInfo? = nil

    var isListening: Bool { remote == nil && (state == "Listen" || proto == .udp) }
    var isEstablished: Bool { remote != nil && (proto == .udp || state == "Established") }
    var service: String? { remote.flatMap { AddressClassifier.service(port: $0.port, proto: proto) } }
}

enum NetworkRelayRole: Equatable {
    case proxyGateway
    case meshVPN

    var title: String {
        switch self {
        case .proxyGateway: return L10n.text("network.role.gateway", defaultValue: "网关")
        case .meshVPN: return L10n.text("network.role.mesh", defaultValue: "组网")
        }
    }
}

enum NetworkRelayClassifier {
    private static let proxyKeywords = [
        "bettbox", "clash", "mihomo", "flclash", "sing-box", "singbox",
        "surge", "shadowrocket", "stash", "loon", "quantumult",
        "v2ray", "xray", "hysteria", "nekoray", "nekobox", "hiddify",
        "karing", "proxifier"
    ]

    private static let meshKeywords = [
        "easytier", "zerotier", "tailscale", "wireguard", "openvpn",
        "nebula", "tinc", "headscale", "cpolar", "frpc", "cloudflared"
    ]

    static func role(appKey: String, appName: String, bundlePath: String? = nil) -> NetworkRelayRole? {
        let haystack = [appKey, appName, bundlePath ?? ""]
            .joined(separator: "\n")
            .lowercased()
        if proxyKeywords.contains(where: { haystack.contains($0) }) { return .proxyGateway }
        if meshKeywords.contains(where: { haystack.contains($0) }) { return .meshVPN }
        return nil
    }
}

struct AppTraffic: Identifiable, Equatable {
    var key: String
    var name: String
    var bundlePath: String?
    var kind: ProcessKind
    var pids: Set<pid_t>
    var rateIn: Double = 0
    var rateOut: Double = 0
    var sessionIn: UInt64 = 0
    var sessionOut: UInt64 = 0
    /// 每分钟流量（最近 60 分钟）。
    var minutes: [TrafficPoint] = []
    var lastActive: Date?

    var id: String { key }
    var sessionTotal: UInt64 { sessionIn &+ sessionOut }
    var rateTotal: Double { rateIn + rateOut }
    var relayRole: NetworkRelayRole? {
        NetworkRelayClassifier.role(appKey: key, appName: name, bundlePath: bundlePath)
    }
    var isRelay: Bool { relayRole != nil }
}

struct NetworkState: Equatable {
    var apps: [AppTraffic] = []
    var flows: [FlowInfo] = []
    var rateIn: Double = 0
    var rateOut: Double = 0
    var sessionIn: UInt64 = 0
    var sessionOut: UInt64 = 0
    /// 最近约 5 分钟的逐次采样速率。
    var live: [TrafficPoint] = []
    /// 最近 60 分钟的每分钟流量。
    var minutes: [TrafficPoint] = []
    var sampledAt: Date?
    var startedAt = Date()

    var activeFlows: [FlowInfo] { flows.filter(\.isEstablished) }
    var onlineApps: [AppTraffic] {
        let keys = Set(activeFlows.filter { $0.scope != .loopback }.map(\.appKey))
        return apps.filter { keys.contains($0.key) }
    }
}

final class NetworkTracker {
    static let liveCapacity = 150
    static let minuteCapacity = 60

    private struct TrackedConnection {
        var bytesIn: UInt64
        var bytesOut: UInt64
        var lastSeen: UInt64
        var endpointKey: String
    }

    private struct AggregatedConnection {
        var bytesIn: UInt64
        var bytesOut: UInt64
        var isTunnel: Bool
        var endpointKey: String
    }

    /// 存活进程下连接瞬时漏采或短暂切换接口时的基线宽限期（30 秒）。
    private static let vanishedConnectionGraceNs: UInt64 = 30_000_000_000

    private let owners = ProcessOwnerResolver()
    private var previousProcess: [pid_t: (UInt64, UInt64)] = [:]
    private var previousConnections: [pid_t: [String: TrackedConnection]] = [:]
    private var previousTime: UInt64?
    private var apps: [String: AppTraffic] = [:]
    private var appMinuteBucket: [String: TrafficPoint] = [:]
    private var totalMinuteBucket = TrafficPoint(bytesIn: 0, bytesOut: 0)
    private var currentMinute: Int?
    private var live = RingBuffer<TrafficPoint>(capacity: liveCapacity)
    private var liveTimed = RingBuffer<LiveSeedPoint>(capacity: liveCapacity)
    private var minutes = RingBuffer<TrafficPoint>(capacity: minuteCapacity)
    private var firstSeen: [String: Date] = [:]
    private var sessionIn: UInt64 = 0
    private var sessionOut: UInt64 = 0
    private let startedAt = Date()

    /// owner 解析可注入，便于测试。
    var ownerLookup: (pid_t, String) -> ProcessOwner
    /// 每分钟结束时回调：分钟序号、各应用流量、应用信息（用于持久化）。
    var onMinuteCompleted: ((Int, [String: TrafficPoint], [String: AppMeta]) -> Void)?
    var geoLookupEnabled = true

    init() {
        let resolver = owners
        ownerLookup = { pid, fallbackName in
            let o = resolver.owner(of: pid)
            // 无法读取路径（其他用户的进程）时 proc_name 也可能为空，退回 nettop 给出的名字。
            return o.name.hasPrefix("pid ") ? ProcessOwner(key: fallbackName, bundlePath: nil, name: fallbackName, kind: .system) : o
        }
    }

    /// - Parameter interval: nettop 的采样间隔。nettop 经管道输出时是块缓冲的，多份采样可能同时到达，
    ///   按到达时间算出的间隔会严重偏小（速率被放大上百倍）；因此优先使用 nettop 自身的采样间隔。
    ///   重启 nettop 后的第一份采样传 nil，按实际间隔计算。
    func ingest(_ sample: NettopSample, now: UInt64 = DispatchTime.now().uptimeNanoseconds, date: Date = Date(),
                interval: TimeInterval? = nil) -> NetworkState {
        let measured = previousTime.map { now > $0 ? Double(now - $0) / 1e9 : 0 } ?? 0
        let elapsed = previousTime == nil ? 0 : (interval ?? measured)
        var currentProcess: [pid_t: (UInt64, UInt64)] = [:]
        var nextConnections: [pid_t: [String: TrackedConnection]] = [:]
        var rates: [String: (Double, Double)] = [:]
        var totalIn: UInt64 = 0, totalOut: UInt64 = 0
        var pidOwner: [pid_t: ProcessOwner] = [:]
        var seenKeys = Set<String>()

        var connsByPID: [pid_t: [String: AggregatedConnection]] = [:]
        for c in sample.connections where c.pid >= 0 {
            let cKey = c.key
            if var existing = connsByPID[c.pid]?[cKey] {
                existing.bytesIn &+= c.bytesIn
                existing.bytesOut &+= c.bytesOut
                existing.isTunnel = existing.isTunnel || c.isTunnelOrP2PInterface
                connsByPID[c.pid]?[cKey] = existing
            } else {
                connsByPID[c.pid, default: [:]][cKey] = AggregatedConnection(
                    bytesIn: c.bytesIn,
                    bytesOut: c.bytesOut,
                    isTunnel: c.isTunnelOrP2PInterface,
                    endpointKey: c.endpointKey
                )
            }
        }

        for p in sample.processes {
            currentProcess[p.pid] = (p.bytesIn, p.bytesOut)
            let owner = ownerLookup(p.pid, p.name)
            pidOwner[p.pid] = owner
            seenKeys.insert(owner.key)
            if apps[owner.key] == nil {
                apps[owner.key] = AppTraffic(key: owner.key, name: owner.name, bundlePath: owner.bundlePath,
                                             kind: owner.kind, pids: [])
            }
            apps[owner.key]?.pids.insert(p.pid)

            let pidConns = connsByPID[p.pid]
            let prevMap = previousConnections[p.pid] ?? [:]
            var consumedPrevKeys = Set<String>()
            var appIn: UInt64 = 0, appOut: UInt64 = 0
            var overviewIn: UInt64 = 0, overviewOut: UInt64 = 0

            if previousTime != nil, let prevProc = previousProcess[p.pid] {
                if let pidConns, !pidConns.isEmpty {
                    // 上轮无明细而本轮突然有明细时，只建立连接基线不计增量，避免把已有连接累计误算成单轮增量。
                    if !(prevMap.isEmpty && (prevProc.0 > 0 || prevProc.1 > 0)) {
                        for (connKey, cur) in pidConns {
                            let prevMatch: TrackedConnection?
                            if let exact = prevMap[connKey] {
                                prevMatch = exact
                                consumedPrevKeys.insert(connKey)
                            } else if let migrated = prevMap.filter({ k, entry in
                                !consumedPrevKeys.contains(k)
                                    && pidConns[k] == nil
                                    && entry.endpointKey == cur.endpointKey
                            }).max(by: { ($0.value.bytesIn &+ $0.value.bytesOut) < ($1.value.bytesIn &+ $1.value.bytesOut) }) {
                                prevMatch = migrated.value
                                consumedPrevKeys.insert(migrated.key)
                            } else {
                                prevMatch = nil
                            }

                            let cIn: UInt64
                            let cOut: UInt64
                            if let prevC = prevMatch {
                                // 单连接计数器回落时记 0，绝不把旧连接全量当增量叠加。
                                cIn = cur.bytesIn >= prevC.bytesIn ? cur.bytesIn - prevC.bytesIn : 0
                                cOut = cur.bytesOut >= prevC.bytesOut ? cur.bytesOut - prevC.bytesOut : 0
                            } else {
                                cIn = cur.bytesIn
                                cOut = cur.bytesOut
                            }
                            appIn &+= cIn
                            appOut &+= cOut
                            if !cur.isTunnel {
                                overviewIn &+= cIn
                                overviewOut &+= cOut
                            }
                        }
                    }
                } else {
                    // 无连接明细行（纯进程样本或无活跃外连回落）：nettop -L 1 进程行是存活连接之和，变小记 0。
                    appIn = p.bytesIn >= prevProc.0 ? p.bytesIn - prevProc.0 : 0
                    appOut = p.bytesOut >= prevProc.1 ? p.bytesOut - prevProc.1 : 0
                    overviewIn = appIn
                    overviewOut = appOut
                }
            }

            var nextMap: [String: TrackedConnection] = [:]
            for (prevKey, entry) in prevMap where !consumedPrevKeys.contains(prevKey) {
                if pidConns?[prevKey] == nil,
                   now >= entry.lastSeen,
                   now - entry.lastSeen <= Self.vanishedConnectionGraceNs {
                    nextMap[prevKey] = entry
                }
            }
            if let pidConns {
                for (connKey, cur) in pidConns {
                    nextMap[connKey] = TrackedConnection(
                        bytesIn: cur.bytesIn,
                        bytesOut: cur.bytesOut,
                        lastSeen: now,
                        endpointKey: cur.endpointKey
                    )
                }
            }
            if !nextMap.isEmpty {
                nextConnections[p.pid] = nextMap
            }

            guard previousTime != nil, previousProcess[p.pid] != nil else { continue }
            if appIn > 0 || appOut > 0 {
                apps[owner.key]?.sessionIn &+= appIn
                apps[owner.key]?.sessionOut &+= appOut
                apps[owner.key]?.lastActive = date
                var r = rates[owner.key] ?? (0, 0)
                r.0 += Double(appIn); r.1 += Double(appOut)
                rates[owner.key] = r
                appMinuteBucket[owner.key, default: TrafficPoint(bytesIn: 0, bytesOut: 0)].bytesIn += Double(appIn)
                appMinuteBucket[owner.key, default: TrafficPoint(bytesIn: 0, bytesOut: 0)].bytesOut += Double(appOut)
            }
            totalIn &+= overviewIn
            totalOut &+= overviewOut
        }

        for key in apps.keys {
            let r = rates[key] ?? (0, 0)
            apps[key]?.rateIn = elapsed > 0 ? r.0 / elapsed : 0
            apps[key]?.rateOut = elapsed > 0 ? r.1 / elapsed : 0
        }
        // 已退出的应用保留流量历史，但清理 pid 集合；从未产生流量的直接移除。
        for key in apps.keys where !seenKeys.contains(key) {
            apps[key]?.pids.removeAll()
            if apps[key]?.sessionTotal == 0 { apps[key] = nil; appMinutes[key] = nil }
        }

        sessionIn &+= totalIn
        sessionOut &+= totalOut
        totalMinuteBucket.bytesIn += Double(totalIn)
        totalMinuteBucket.bytesOut += Double(totalOut)
        if previousTime != nil, elapsed > 0 {
            let pt = TrafficPoint(bytesIn: Double(totalIn) / elapsed, bytesOut: Double(totalOut) / elapsed)
            live.append(pt)
            liveTimed.append(LiveSeedPoint(timestamp: date.timeIntervalSince1970, bytesIn: pt.bytesIn, bytesOut: pt.bytesOut))
        }
        rollMinute(date)

        // 连接
        var flows: [FlowInfo] = []
        var aliveFlowKeys = Set<String>()
        flows.reserveCapacity(sample.connections.count)
        for c in sample.connections {
            let owner = pidOwner[c.pid] ?? ownerLookup(c.pid, "pid \(c.pid)")
            let key = c.key
            aliveFlowKeys.insert(key)
            let seen = firstSeen[key] ?? date
            firstSeen[key] = seen
            let scope = c.remote.map { AddressScopes.scope(of: $0.address) } ?? .loopback
            let geo = (scope == .internet && geoLookupEnabled) ? c.remote.flatMap { GeoIP.lookup($0.address) } : nil
            flows.append(FlowInfo(id: key, appKey: owner.key, appName: owner.name, pid: c.pid, proto: c.proto,
                                  local: c.local, remote: c.remote, state: c.state, scope: scope,
                                  bytesIn: c.bytesIn, bytesOut: c.bytesOut, firstSeen: seen, geo: geo))
        }
        firstSeen = firstSeen.filter { aliveFlowKeys.contains($0.key) }

        let alivePIDs = Set(currentProcess.keys)
        owners.prune(alive: alivePIDs)
        previousProcess = currentProcess
        previousConnections = nextConnections
        previousTime = now

        var state = NetworkState()
        state.apps = apps.values.sorted { ($0.rateTotal, $0.sessionTotal) > ($1.rateTotal, $1.sessionTotal) }
        state.flows = flows
        state.rateIn = live.last?.bytesIn ?? 0
        state.rateOut = live.last?.bytesOut ?? 0
        state.sessionIn = sessionIn
        state.sessionOut = sessionOut
        state.live = live.elements
        state.minutes = minutes.elements + [totalMinuteBucket]
        state.sampledAt = date
        state.startedAt = startedAt
        return state
    }

    private var appMinutes: [String: RingBuffer<TrafficPoint>] = [:]

    func liveSeedSnapshot(now: Date = Date()) -> LiveSeedSnapshot {
        LiveSeedSnapshot(savedAt: now.timeIntervalSince1970, points: liveTimed.elements)
    }

    func preloadLive(_ points: [TrafficPoint], now: Date = Date(), stepSeconds: TimeInterval = 2.0) {
        live.removeAll()
        liveTimed.removeAll()
        let slice = Array(points.suffix(Self.liveCapacity))
        guard !slice.isEmpty else { return }
        let baseTs = now.timeIntervalSince1970
        for (i, pt) in slice.enumerated() {
            let ts = baseTs - Double(slice.count - 1 - i) * stepSeconds
            live.append(pt)
            liveTimed.append(LiveSeedPoint(timestamp: ts, bytesIn: pt.bytesIn, bytesOut: pt.bytesOut))
        }
    }

    private func meta(for keys: [String]) -> [String: AppMeta] {
        var m: [String: AppMeta] = [:]
        for k in keys {
            if let a = apps[k] { m[k] = AppMeta(key: k, name: a.name, bundlePath: a.bundlePath, kind: a.kind) }
        }
        return m
    }

    /// 取出当前未满一分钟的流量（退出前写入持久化存储），并清空该桶以免重复计入。
    func takePartialMinute() -> (Int, [String: TrafficPoint], [String: AppMeta])? {
        guard let current = currentMinute, !appMinuteBucket.isEmpty else { return nil }
        let result = (current, appMinuteBucket, meta(for: Array(appMinuteBucket.keys)))
        appMinuteBucket.removeAll()
        totalMinuteBucket = TrafficPoint(bytesIn: 0, bytesOut: 0)
        return result
    }

    /// 启动时用持久化数据恢复最近 60 分钟（按分钟对齐，缺失补 0）。
    /// 当前分钟的已有流量放入当前桶，后续写入时会与之累加。
    func preload(perApp: [String: [Int: TrafficPoint]], nowMinute: Int) {
        let first = nowMinute - NetworkTracker.minuteCapacity
        var totals = [TrafficPoint](repeating: TrafficPoint(bytesIn: 0, bytesOut: 0), count: NetworkTracker.minuteCapacity)
        for (key, minutes) in perApp {
            var ring = RingBuffer<TrafficPoint>(capacity: NetworkTracker.minuteCapacity)
            for m in first..<nowMinute {
                let p = minutes[m] ?? TrafficPoint(bytesIn: 0, bytesOut: 0)
                ring.append(p)
                totals[m - first].bytesIn += p.bytesIn
                totals[m - first].bytesOut += p.bytesOut
            }
            appMinutes[key] = ring
        }
        minutes.removeAll()
        totals.forEach { minutes.append($0) }
        currentMinute = nowMinute
        // 当前分钟已持久化的部分不放入内存桶（否则退出时会重复写入），图表会在下一分钟补齐。
    }

    private func rollMinute(_ date: Date) {
        let minute = Int(date.timeIntervalSince1970 / 60)
        if currentMinute == nil { currentMinute = minute }
        guard let current = currentMinute, minute > current else {
            for key in apps.keys {
                apps[key]?.minutes = (appMinutes[key]?.elements ?? []) + [appMinuteBucket[key] ?? TrafficPoint(bytesIn: 0, bytesOut: 0)]
            }
            return
        }
        // 跨分钟：把当前桶写入历史；中间空缺的分钟补 0。
        onMinuteCompleted?(current, appMinuteBucket, meta(for: Array(appMinuteBucket.keys)))
        let gap = min(minute - current, NetworkTracker.minuteCapacity)
        for i in 0..<gap {
            let zero = TrafficPoint(bytesIn: 0, bytesOut: 0)
            minutes.append(i == 0 ? totalMinuteBucket : zero)
            for key in apps.keys {
                appMinutes[key, default: RingBuffer(capacity: NetworkTracker.minuteCapacity)]
                    .append(i == 0 ? (appMinuteBucket[key] ?? zero) : zero)
            }
        }
        totalMinuteBucket = TrafficPoint(bytesIn: 0, bytesOut: 0)
        appMinuteBucket.removeAll()
        currentMinute = minute
        for key in apps.keys { apps[key]?.minutes = (appMinutes[key]?.elements ?? []) + [TrafficPoint(bytesIn: 0, bytesOut: 0)] }
    }
}
