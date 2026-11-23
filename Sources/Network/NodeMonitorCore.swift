//
//  NodeMonitorCore.swift
//  Zest
//
//  Bettbox（Mihomo）节点与分组出口连通监测的纯逻辑层：不读文件、不联网、不落盘。
//  包含 /proxies 解码、策略组拓扑与穿透解析、被动历史清洗（3900ms 超时边界判离线、30s 冷却折叠、
//  15s 断网/重载风暴门控）、主动探测分桶与链式前置联动规划、等权汇总与指标聚合。
//

import Foundation

// MARK: - Bettbox 配置与 /proxies 模型

struct BettboxProfileInfo: Equatable, Sendable {
    var id: String
    var label: String

    static let fallback = BettboxProfileInfo(id: "default", label: "")
}

struct ProxyHistoryEntry: Decodable, Equatable, Sendable {
    var time: String
    var delay: Int

    private enum CodingKeys: String, CodingKey { case time, delay }

    init(time: String, delay: Int) {
        self.time = time
        self.delay = delay
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = (try c.decodeIfPresent(String.self, forKey: .time)) ?? ""
        delay = (try c.decodeIfPresent(Int.self, forKey: .delay)) ?? 0
    }
}

struct ProxyExtraEntry: Decodable, Equatable, Sendable {
    var alive: Bool
    var history: [ProxyHistoryEntry]

    private enum CodingKeys: String, CodingKey { case alive, history }

    init(alive: Bool = false, history: [ProxyHistoryEntry] = []) {
        self.alive = alive
        self.history = history
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        alive = (try c.decodeIfPresent(Bool.self, forKey: .alive)) ?? false
        history = (try c.decodeIfPresent([ProxyHistoryEntry].self, forKey: .history)) ?? []
    }
}

struct ProxyEntry: Decodable, Equatable, Sendable {
    var name: String
    var type: String
    var alive: Bool
    var dialerProxy: String
    var all: [String]?
    var now: String?
    var history: [ProxyHistoryEntry]
    var extra: [String: ProxyExtraEntry]

    private enum CodingKeys: String, CodingKey {
        case name, type, alive, all, now, history, extra
        case dialerProxy = "dialer-proxy"
    }

    init(name: String, type: String, alive: Bool = false, dialerProxy: String = "",
         all: [String]? = nil, now: String? = nil, history: [ProxyHistoryEntry] = [],
         extra: [String: ProxyExtraEntry] = [:]) {
        self.name = name
        self.type = type
        self.alive = alive
        self.dialerProxy = dialerProxy
        self.all = all
        self.now = now
        self.history = history
        self.extra = extra
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        type = (try c.decodeIfPresent(String.self, forKey: .type)) ?? ""
        alive = (try c.decodeIfPresent(Bool.self, forKey: .alive)) ?? false
        dialerProxy = (try c.decodeIfPresent(String.self, forKey: .dialerProxy)) ?? ""
        all = try c.decodeIfPresent([String].self, forKey: .all)
        now = try c.decodeIfPresent(String.self, forKey: .now)
        history = (try c.decodeIfPresent([ProxyHistoryEntry].self, forKey: .history)) ?? []
        extra = (try c.decodeIfPresent([String: ProxyExtraEntry].self, forKey: .extra)) ?? [:]
    }

    static let builtInTypes: Set<String> = ["Direct", "Reject", "RejectDrop", "Pass", "PassRule", "Compatible", "Dns"]
    static let groupTypes: Set<String> = ["Selector", "URLTest", "Fallback", "LoadBalance", "Relay"]

    var isGroup: Bool { all != nil || Self.groupTypes.contains(type) }
    var isBuiltIn: Bool { Self.builtInTypes.contains(type) }
    var isMonitorableLeaf: Bool { !isGroup && !isBuiltIn && !name.isEmpty }
    var isChain: Bool { !dialerProxy.isEmpty }
    var key: NodeKey { NodeKey(name: name, dialer: dialerProxy) }
}

struct BettboxProxiesPayload: Decodable, Equatable, Sendable {
    var proxies: [String: ProxyEntry]

    private enum CodingKeys: String, CodingKey { case proxies }

    init(proxies: [String: ProxyEntry] = [:]) {
        self.proxies = proxies
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = (try c.decodeIfPresent([String: ProxyEntry].self, forKey: .proxies)) ?? [:]
        var normalized: [String: ProxyEntry] = [:]
        normalized.reserveCapacity(raw.count)
        for (dictKey, var entry) in raw {
            if entry.name.isEmpty { entry.name = dictKey }
            normalized[dictKey] = entry
        }
        proxies = normalized
    }
}

// MARK: - 统计主键、三态、探测样本与聚合指标

/// 节点统计主键：(节点名, dialer-proxy)。同名节点在不同配置下换前置链时不混算。
struct NodeKey: Hashable, Equatable, Codable, Sendable, Identifiable {
    var name: String
    var dialer: String

    var id: String { "\(name)\u{1F}\(dialer)" }
    var isChain: Bool { !dialer.isEmpty }
}

/// 严格三态：无任何探测历史一律为 `.untested`，绝不将 Mihomo 默认 `alive: true` 误判为在线。
enum NodeLiveState: Equatable, Sendable {
    case online
    case offline
    case untested
}

enum NodeProbeSource: Int, Equatable, Codable, Sendable {
    case passive = 0
    case active = 1
}

enum NodeSourceFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case activeOnly
    var id: String { rawValue }
}

struct NodeProbeSample: Equatable, Sendable {
    var tsMs: Int64
    var node: String
    var dialer: String
    var nodeType: String
    var delayMs: Int
    var ok: Bool
    var source: NodeProbeSource

    var key: NodeKey { NodeKey(name: node, dialer: dialer) }

    init(tsMs: Int64, node: String, dialer: String, nodeType: String, delayMs: Int, ok: Bool, source: NodeProbeSource) {
        self.tsMs = tsMs
        self.node = node
        self.dialer = dialer
        self.nodeType = nodeType
        let validOk = ok && delayMs > 0
        self.ok = validOk
        self.delayMs = validOk ? delayMs : 0
        self.source = source
    }
}

/// 分组服务通道的单次探测样本（1A 视角：统计记在 `(profileId, groupName)` 通道头上，切换节点无缝续算）。
struct GroupWatchSample: Equatable, Sendable {
    var tsMs: Int64
    var profileId: String
    var groupName: String
    var currentNode: String
    var dialer: String
    var delayMs: Int
    var ok: Bool

    init(tsMs: Int64, profileId: String, groupName: String, currentNode: String, dialer: String, delayMs: Int, ok: Bool) {
        self.tsMs = tsMs
        self.profileId = profileId
        self.groupName = groupName
        self.currentNode = currentNode
        self.dialer = dialer
        let validOk = ok && delayMs > 0
        self.ok = validOk
        self.delayMs = validOk ? delayMs : 0
    }
}

struct GroupWatchLatest: Equatable, Sendable {
    var tsMs: Int64
    var currentNode: String
    var dialer: String
    var ok: Bool
    var delayMs: Int
    var consecutiveFailures: Int
}

struct GroupWatchSummaryRecord: Identifiable, Equatable, Sendable {
    var groupName: String
    var currentNode: String
    var dialer: String
    var day1 = NodeWindowMetrics()
    var day7 = NodeWindowMetrics()
    var day30 = NodeWindowMetrics()
    var latest: GroupWatchLatest?
    var hourly24: [NodeHourPoint] = []

    var id: String { groupName }

    /// 仅当最近一次探测记录属于当前出站节点时，才把它的在线/离线与连续超时角标归到当前节点。
    var latestMatchesCurrentNode: Bool {
        guard let latest else { return false }
        return latest.currentNode == currentNode && latest.dialer == dialer
    }

    var liveState: NodeLiveState {
        guard let latest, latestMatchesCurrentNode else { return .untested }
        return latest.ok ? .online : .offline
    }

    func metrics(for range: NodeStatsRange) -> NodeWindowMetrics {
        switch range {
        case .day1: return day1
        case .day7: return day7
        case .day30: return day30
        }
    }
}

enum NodeStatsRange: String, CaseIterable, Identifiable, Sendable {
    case day1, day7, day30
    var id: String { rawValue }
}

/// 某时间窗口内的在线率与加权延时指标。
struct NodeWindowMetrics: Equatable, Sendable {
    static let lowSampleThreshold = 3

    var probes: Int = 0
    var ok: Int = 0
    var sumDelayMs: Int64 = 0
    var minDelayMs: Int?
    var maxDelayMs: Int?

    var uptimeRate: Double? { probes > 0 ? Double(ok) / Double(probes) : nil }
    var avgDelayMs: Int? { ok > 0 ? Int((Double(sumDelayMs) / Double(ok)).rounded()) : nil }
    var isLowSample: Bool { probes > 0 && probes < Self.lowSampleThreshold }

    mutating func merge(_ other: NodeWindowMetrics) {
        probes += other.probes
        ok += other.ok
        sumDelayMs += other.sumDelayMs
        if let m = other.minDelayMs, m > 0 {
            minDelayMs = minDelayMs.map { min($0, m) } ?? m
        }
        if let m = other.maxDelayMs, m > 0 {
            maxDelayMs = maxDelayMs.map { max($0, m) } ?? m
        }
    }
}

/// 等权节点聚合统计：避免 90s 高频策略组节点以样本数量淹没其他低频节点。
struct NodeEqualWeightAggregate: Equatable, Sendable {
    var sampledNodeCount: Int = 0
    var totalProbes: Int = 0
    var totalOk: Int = 0
    var avgUptimeRate: Double?
    var avgDelayMs: Int?
    var minDelayMs: Int?
    var maxDelayMs: Int?

    static func compute(from metricsList: [NodeWindowMetrics]) -> NodeEqualWeightAggregate {
        var sampled = 0
        var uptimeSum = 0.0
        var delayNodeCount = 0
        var delaySum = 0.0
        var probes = 0
        var ok = 0
        var lo: Int?
        var hi: Int?

        for m in metricsList where m.probes > 0 {
            sampled += 1
            probes += m.probes
            ok += m.ok
            if let r = m.uptimeRate { uptimeSum += r }
            if let d = m.avgDelayMs {
                delayNodeCount += 1
                delaySum += Double(d)
            }
            if let mn = m.minDelayMs, mn > 0 { lo = lo.map { min($0, mn) } ?? mn }
            if let mx = m.maxDelayMs, mx > 0 { hi = hi.map { max($0, mx) } ?? mx }
        }
        return NodeEqualWeightAggregate(
            sampledNodeCount: sampled,
            totalProbes: probes,
            totalOk: ok,
            avgUptimeRate: sampled > 0 ? uptimeSum / Double(sampled) : nil,
            avgDelayMs: delayNodeCount > 0 ? Int((delaySum / Double(delayNodeCount)).rounded()) : nil,
            minDelayMs: lo,
            maxDelayMs: hi
        )
    }
}

struct NodeLatestProbe: Equatable, Sendable {
    var tsMs: Int64
    var ok: Bool
    var delayMs: Int
    var source: NodeProbeSource
}

enum NodeSlotHealth: Equatable, Sendable {
    case noData
    case healthy
    case degraded
    case down
}

struct NodeHourPoint: Identifiable, Equatable, Sendable {
    var hour: Int
    var metrics: NodeWindowMetrics
    var id: Int { hour }

    var health: NodeSlotHealth {
        guard let rate = metrics.uptimeRate else { return .noData }
        if rate >= 0.95 { return .healthy }
        if rate >= 0.50 { return .degraded }
        return .down
    }
}

struct NodeDayPoint: Identifiable, Equatable, Sendable {
    var day: Int
    var metrics: NodeWindowMetrics
    var id: Int { day }
}

struct NodeSummaryRecord: Equatable, Sendable {
    var key: NodeKey
    var nodeType: String
    var day1 = NodeWindowMetrics()
    var day7 = NodeWindowMetrics()
    var day30 = NodeWindowMetrics()
    var latest: NodeLatestProbe?
    var hourly24: [NodeHourPoint] = []

    func metrics(for range: NodeStatsRange) -> NodeWindowMetrics {
        switch range {
        case .day1: return day1
        case .day7: return day7
        case .day30: return day30
        }
    }
}

// MARK: - 拓扑、链式前置与分组穿透解析

struct ProxyGroupInfo: Identifiable, Equatable, Sendable {
    var name: String
    var type: String
    var now: String?
    var directMembers: [String]
    var resolvedLeaves: Set<NodeKey>

    var id: String { name }
}

enum DialerResolution: Equatable, Sendable {
    case direct
    case leaf(NodeKey)
    case group(groupName: String, currentLeaf: NodeKey?)
    case unresolved(String)

    var upstreamLeaf: NodeKey? {
        switch self {
        case .leaf(let k): return k
        case .group(_, let leaf): return leaf
        case .direct, .unresolved: return nil
        }
    }
}

struct NodeTopology: Equatable, Sendable {
    var raw: [String: ProxyEntry]
    var leaves: [NodeKey: ProxyEntry]
    var leafByName: [String: NodeKey]
    var groups: [ProxyGroupInfo]
    var groupsByName: [String: ProxyGroupInfo]
    var leafGroups: [NodeKey: [String]]

    /// - Parameter groupOrder: 从 `config.yaml` 的 `proxy-groups` 解析出的策略组名称顺序。
    ///   用于补齐 `GLOBAL.all` 缺失或未包含的策略组；缺省时行为与旧版一致（仅 `GLOBAL.all` + 名称兜底）。
    init(payload: BettboxProxiesPayload, groupOrder: [String] = []) {
        self.raw = payload.proxies
        var leavesMap: [NodeKey: ProxyEntry] = [:]
        var byName: [String: NodeKey] = [:]
        for entry in payload.proxies.values where entry.isMonitorableLeaf {
            leavesMap[entry.key] = entry
            byName[entry.name] = entry.key
        }
        self.leaves = leavesMap
        self.leafByName = byName

        // 递归展开策略组里的叶节点（用 visited 防止循环引用）。
        func resolveLeaves(of groupName: String, visited: inout Set<String>) -> Set<NodeKey> {
            guard visited.insert(groupName).inserted, let group = payload.proxies[groupName], let members = group.all else {
                return []
            }
            var result = Set<NodeKey>()
            for m in members {
                guard let entry = payload.proxies[m] else { continue }
                if entry.isGroup {
                    result.formUnion(resolveLeaves(of: m, visited: &visited))
                } else if entry.isMonitorableLeaf {
                    result.insert(entry.key)
                }
            }
            return result
        }

        var groupList: [ProxyGroupInfo] = []
        var groupMap: [String: ProxyGroupInfo] = [:]
        var membership: [NodeKey: [String]] = [:]

        for name in Self.groupOrdering(payload: payload, groupOrder: groupOrder) {
            guard let entry = payload.proxies[name], let members = entry.all else { continue }
            var visited = Set<String>()
            let resolved = resolveLeaves(of: name, visited: &visited)
            let info = ProxyGroupInfo(name: name, type: entry.type, now: entry.now, directMembers: members, resolvedLeaves: resolved)
            groupList.append(info)
            groupMap[name] = info
            for leaf in resolved {
                membership[leaf, default: []].append(name)
            }
        }
        // 叶节点所属分组同样按拓扑顺序排列（resolveLeaves 返回 Set，顺序不稳定）。
        let orderIndex = Dictionary(uniqueKeysWithValues: groupList.enumerated().map { ($1.name, $0) })
        self.groups = groupList
        self.groupsByName = groupMap
        self.leafGroups = membership.mapValues { names in
            names.sorted { (orderIndex[$0] ?? .max) < (orderIndex[$1] ?? .max) }
        }
    }

    /// 策略组展示顺序，与 Bettbox / Clash 原序一致：
    /// ① `GLOBAL.all` 中真实策略组的首次出现顺序；
    /// ② 调用方传入的 `config.yaml` `proxy-groups` 顺序，补齐 `GLOBAL.all` 缺失或未包含的组；
    /// ③ 仍未覆盖的策略组按名称排序兜底。
    static func groupOrdering(payload: BettboxProxiesPayload, groupOrder: [String] = []) -> [String] {
        func isRealGroup(_ name: String) -> Bool {
            name != "GLOBAL" && payload.proxies[name]?.all != nil
        }
        var ordered: [String] = []
        var seen = Set<String>()
        for name in payload.proxies["GLOBAL"]?.all ?? [] where isRealGroup(name) {
            if seen.insert(name).inserted { ordered.append(name) }
        }
        for name in groupOrder where isRealGroup(name) {
            if seen.insert(name).inserted { ordered.append(name) }
        }
        ordered.append(contentsOf: payload.proxies.keys.filter { isRealGroup($0) && !seen.contains($0) }.sorted())
        return ordered
    }

    /// 沿策略组的 `now` 指针穿透嵌套组，解析当前实际出站的叶节点（遇到 DIRECT/REJECT/环 返回 nil）。
    func resolveCurrentLeaf(ofGroup groupName: String) -> ProxyEntry? {
        guard var current = raw[groupName], current.isGroup else { return nil }
        var visited: Set<String> = [groupName]
        while current.isGroup {
            guard let nextName = current.now, visited.insert(nextName).inserted, let next = raw[nextName] else {
                return nil
            }
            if next.isMonitorableLeaf { return next }
            current = next
        }
        return nil
    }

    /// 解析链式节点的前置依赖（叶节点直接返回；策略组沿 `now` 向下追踪到当前实际叶节点）。
    func resolveDialer(for key: NodeKey) -> DialerResolution {
        guard !key.dialer.isEmpty else { return .direct }
        guard let target = raw[key.dialer] else { return .unresolved(key.dialer) }
        if target.isMonitorableLeaf {
            return .leaf(target.key)
        }
        if target.isGroup {
            let leaf = resolveCurrentLeaf(ofGroup: key.dialer)
            return .group(groupName: key.dialer, currentLeaf: leaf?.key)
        }
        return .unresolved(key.dialer)
    }
}

// MARK: - 被动历史解析、超时清洗、冷却折叠与风暴门控

enum MihomoTimestamp {
    private static let lock = NSLock()
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseMs(_ raw: String) -> Int64? {
        guard !raw.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let d = withFraction.date(from: raw) ?? plain.date(from: raw) {
            return Int64((d.timeIntervalSince1970 * 1000.0).rounded())
        }
        return nil
    }
}

enum PassiveHistoryExtractor {
    /// 只吸收最近 24 小时内的被动历史点，防止早于 node_probes 保留期的陈旧记录反复重算。
    static let maxAgeMs: Int64 = 24 * 3600 * 1000
    /// 冷却窗口 30 秒：消除同一节点被 2–3 个重叠策略组在 50–600ms 内并发测速造成的重复计数。
    static let cooldownMs: Int64 = 30_000
    /// Mihomo `unified-delay: true` 超时边界（策略组 4000ms / Bettbox 5000ms）会被记作 4000–5003ms 假在线；
    /// 被动吸收将 >= 3900ms 判定为超时/离线，避免拉爆在线率与平均延时。
    static let passiveTimeoutThresholdMs: Int = 3900
    /// 断网/重载风暴门控：同 15 秒窗口内 ≥ 10 个不同节点参与且失败率 ≥ 80% 时，整批失败样本判定为异常风暴丢弃。
    static let stormBucketMs: Int64 = 15_000
    static let stormMinNodes: Int = 10
    static let stormFailRateThreshold: Double = 0.80

    struct ExtractResult: Equatable, Sendable {
        var samples: [NodeProbeSample]
        /// 被风暴门控主动丢弃的失败样本水位，调用方必须推进 lastSeenMs 防止次轮因桶人数跌破阈值而漏写。
        var droppedWatermarks: [NodeKey: Int64]
    }

    static func isValidPassiveDelay(_ delay: Int, timeoutThresholdMs: Int = passiveTimeoutThresholdMs) -> Bool {
        delay > 0 && delay < timeoutThresholdMs
    }

    /// 统一历史源选择：仅当 `extra[preferredURL]` 非空且其最新时间不早于顶层 `entry.history` 时采用之，
    /// 防止单次主动探测写入 `extra` 后永久遮蔽 Mihomo 策略组后续写入顶层 `history` 的健康检查。
    static func effectiveHistory(for entry: ProxyEntry,
                                 preferredURL: String = BettboxClient.defaultProbeURL) -> [ProxyHistoryEntry] {
        let top = entry.history
        guard let pref = entry.extra[preferredURL]?.history, !pref.isEmpty else {
            return top
        }
        guard !top.isEmpty else { return pref }
        let prefMax = pref.compactMap { MihomoTimestamp.parseMs($0.time) }.max() ?? Int64.min
        let topMax = top.compactMap { MihomoTimestamp.parseMs($0.time) }.max() ?? Int64.min
        return prefMax >= topMax ? pref : top
    }

    /// 统一三态实时兜底（供面板摘要与主窗口共用）：严格受 `maxAgeMs` 与 `clearedAtMs` 约束，避免清库后历史回魂。
    static func latestValidFallback(for entry: ProxyEntry,
                                    nowMs: Int64,
                                    clearedAtMs: Int64 = 0,
                                    preferredURL: String = BettboxClient.defaultProbeURL,
                                    timeoutThresholdMs: Int = passiveTimeoutThresholdMs) -> (ok: Bool, delayMs: Int, tsMs: Int64)? {
        let minAllowedMs = max(nowMs - maxAgeMs, clearedAtMs)
        let maxAllowedMs = nowMs + 5 * 60 * 1000
        var best: (tsMs: Int64, delay: Int)?
        for h in effectiveHistory(for: entry, preferredURL: preferredURL) {
            guard let tsMs = MihomoTimestamp.parseMs(h.time),
                  tsMs > minAllowedMs, tsMs <= maxAllowedMs else { continue }
            if best == nil || tsMs >= best!.tsMs {
                best = (tsMs, h.delay)
            }
        }
        guard let best else { return nil }
        let valid = isValidPassiveDelay(best.delay, timeoutThresholdMs: timeoutThresholdMs)
        return (valid, valid ? best.delay : 0, best.tsMs)
    }

    static func extract(from topology: NodeTopology, now: Date,
                        lastSeenMs: [NodeKey: Int64] = [:],
                        clearedAtMs: Int64 = 0,
                        preferredURL: String = BettboxClient.defaultProbeURL,
                        timeoutThresholdMs: Int = passiveTimeoutThresholdMs) -> [NodeProbeSample] {
        extractWithWatermarks(from: topology, now: now, lastSeenMs: lastSeenMs,
                              clearedAtMs: clearedAtMs, preferredURL: preferredURL,
                              timeoutThresholdMs: timeoutThresholdMs).samples
    }

    static func extractWithWatermarks(from topology: NodeTopology, now: Date,
                                      lastSeenMs: [NodeKey: Int64] = [:],
                                      clearedAtMs: Int64 = 0,
                                      preferredURL: String = BettboxClient.defaultProbeURL,
                                      timeoutThresholdMs: Int = passiveTimeoutThresholdMs) -> ExtractResult {
        let nowMs = Int64((now.timeIntervalSince1970 * 1000.0).rounded())
        let minAllowedMs = max(nowMs - maxAgeMs, clearedAtMs)
        let maxAllowedMs = nowMs + 5 * 60 * 1000   // 容忍微小系统时钟偏移
        var candidates: [NodeProbeSample] = []

        for (key, entry) in topology.leaves {
            let rawHistory = effectiveHistory(for: entry, preferredURL: preferredURL)

            let prevSeen = lastSeenMs[key] ?? Int64.min
            let parsed: [(tsMs: Int64, delay: Int)] = rawHistory.compactMap { h in
                guard let tsMs = MihomoTimestamp.parseMs(h.time),
                      tsMs > minAllowedMs, tsMs <= maxAllowedMs,
                      tsMs > prevSeen else { return nil }
                return (tsMs, h.delay)
            }.sorted { $0.tsMs < $1.tsMs }

            guard !parsed.isEmpty else { continue }

            // 30 秒冷却折叠：把同一批多策略组在数秒内产生的突发点聚成簇，每个簇保留最后一条；
            // 若首簇距上一次已落盘的 lastSeenMs 仍不足 30 秒，则忽略不重复计入。
            var clusters: [(tsMs: Int64, delay: Int)] = []
            var clusterAnchor = prevSeen
            var currentClusterLatest: (tsMs: Int64, delay: Int)?

            for item in parsed {
                if let cur = currentClusterLatest {
                    if item.tsMs - cur.tsMs < cooldownMs {
                        currentClusterLatest = item
                    } else {
                        clusters.append(cur)
                        clusterAnchor = cur.tsMs
                        currentClusterLatest = (item.tsMs - clusterAnchor >= cooldownMs) ? item : nil
                    }
                } else {
                    if clusterAnchor == Int64.min || (item.tsMs - clusterAnchor) >= cooldownMs {
                        currentClusterLatest = item
                    }
                }
            }
            if let last = currentClusterLatest {
                clusters.append(last)
            }

            for item in clusters {
                let valid = isValidPassiveDelay(item.delay, timeoutThresholdMs: timeoutThresholdMs)
                candidates.append(NodeProbeSample(tsMs: item.tsMs, node: entry.name, dialer: entry.dialerProxy,
                                                  nodeType: entry.type, delayMs: valid ? item.delay : 0,
                                                  ok: valid, source: .passive))
            }
        }

        guard !candidates.isEmpty else { return ExtractResult(samples: [], droppedWatermarks: [:]) }

        // 15 秒风暴门控：识别本机断网或配置重载打爆瞬间的群体失败，整桶丢弃失败样本并回传丢弃水位。
        var bucketStats: [Int64: (nodes: Set<NodeKey>, total: Int, failed: Int)] = [:]
        for s in candidates {
            let b = s.tsMs / stormBucketMs
            var st = bucketStats[b] ?? (Set<NodeKey>(), 0, 0)
            st.nodes.insert(s.key)
            st.total += 1
            if !s.ok { st.failed += 1 }
            bucketStats[b] = st
        }
        var stormBuckets = Set<Int64>()
        for (b, st) in bucketStats {
            if st.nodes.count >= stormMinNodes && Double(st.failed) / Double(st.total) >= stormFailRateThreshold {
                stormBuckets.insert(b)
            }
        }

        var droppedWatermarks: [NodeKey: Int64] = [:]
        var filtered: [NodeProbeSample] = []
        filtered.reserveCapacity(candidates.count)
        for s in candidates {
            if !stormBuckets.isEmpty && stormBuckets.contains(s.tsMs / stormBucketMs) && !s.ok {
                let prev = droppedWatermarks[s.key] ?? Int64.min
                if s.tsMs > prev { droppedWatermarks[s.key] = s.tsMs }
            } else {
                filtered.append(s)
            }
        }
        filtered.sort { $0.tsMs < $1.tsMs || ($0.tsMs == $1.tsMs && $0.node < $1.node) }
        return ExtractResult(samples: filtered, droppedWatermarks: droppedWatermarks)
    }
}

// MARK: - 主动探测配置与分桶调度（含链式前置联动与分组服务通道）

struct NodeProbeScope: Codable, Equatable, Sendable {
    /// 候选组全量低频主动探测的策略组名。
    var groups: [String] = []
    /// 额外单选的节点名。
    var nodes: [String] = []
    /// 持续盯住当前出站节点的分组（5 分钟监测，服务通道视角，连续 2 次断线通知）。
    var watchedGroups: [String] = []

    var isEmpty: Bool { groups.isEmpty && nodes.isEmpty }
    var hasWatchedGroups: Bool { !watchedGroups.isEmpty }
    var hasAnySelection: Bool { !isEmpty || hasWatchedGroups }

    private enum CodingKeys: String, CodingKey { case groups, nodes, watchedGroups }

    init(groups: [String] = [], nodes: [String] = [], watchedGroups: [String] = []) {
        self.groups = groups
        self.nodes = nodes
        self.watchedGroups = watchedGroups
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groups = (try c.decodeIfPresent([String].self, forKey: .groups)) ?? []
        nodes = (try c.decodeIfPresent([String].self, forKey: .nodes)) ?? []
        watchedGroups = (try c.decodeIfPresent([String].self, forKey: .watchedGroups)) ?? []
    }
}

struct ActiveProbeTarget: Equatable, Sendable {
    var key: NodeKey
    var nodeType: String
    /// 同一落地桶内的链式节点串行限流，避免瞬间打爆同一落地机；普通节点为 nil（共享总并发池）。
    var landingBucket: String?
}

/// 分组监测的本轮执行计划：按最终叶节点去重，多个分组共用同一出口时只测 1 次。
struct WatchedGroupPlanItem: Equatable, Sendable {
    var groupName: String
    var leaf: ProxyEntry
}

/// 主动测速过程中的单条实时完成记录（仅在测速进行时跨进程广播，空闲零开销）。
struct NodeProbeLiveEvent: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var node: String
    var groupName: String?
    var ok: Bool
    var delayMs: Int
    var tsMs: Int64
}

/// 主动测速实时进度快照（用于主窗口动态进度卡片、正在测速节点脉冲与行内「测速中」状态）。
struct NodeProbeLiveProgress: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case checkingDirect
        case watchingGroups
        case probingBulk
        case finished
        case cancelled
        case skippedOffline
    }

    var runId: Int
    var phase: Phase
    var total: Int
    var completed: Int
    var online: Int
    var offline: Int
    var activeNodes: [String]
    var recentResults: [NodeProbeLiveEvent]
    var flushedSamples: Int
    var updatedAt: Double

    var isRunning: Bool {
        phase == .checkingDirect || phase == .watchingGroups || phase == .probingBulk
    }
}

// MARK: - 自定义分组趋势对比（正则自动提取 / 自由规则混搭：正则 + 策略组 + 手选节点 + 链式筛选）

enum NodeRuleKindFilter: String, Codable, CaseIterable, Identifiable, Sendable {
    case all
    case directOnly
    case chainOnly
    var id: String { rawValue }

    func matches(isChain: Bool) -> Bool {
        switch self {
        case .all: return true
        case .directOnly: return !isChain
        case .chainOnly: return isChain
        }
    }
}

/// 单条分组规则：链路筛选（AND）配合「名称正则 / Bettbox 策略组 / 手选节点」（任一非空条件命中即归入；三者皆空则按链路筛选全收）。
struct NodeTrendGroupRule: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name: String
    var kindFilter: NodeRuleKindFilter = .all
    var regex: String = ""
    var bettboxGroups: [String] = []
    var explicitNodes: [String] = []

    init(id: UUID = UUID(), name: String, kindFilter: NodeRuleKindFilter = .all,
         regex: String = "", bettboxGroups: [String] = [], explicitNodes: [String] = []) {
        self.id = id
        self.name = name
        self.kindFilter = kindFilter
        self.regex = regex
        self.bettboxGroups = bettboxGroups
        self.explicitNodes = explicitNodes
    }
}

/// 一套可随时切换的趋势分组方案（持久化在本地设置中，零后台采样开销）。
struct NodeTrendGroupSet: Codable, Equatable, Identifiable, Sendable {
    enum Mode: String, Codable, CaseIterable, Identifiable, Sendable {
        case customRules
        case regexCapture
        var id: String { rawValue }
    }

    var id: UUID = UUID()
    var name: String
    var mode: Mode = .customRules
    var defaultKindFilter: NodeRuleKindFilter = .all
    /// `.regexCapture` 模式下使用的正则表达式（取第 1 个捕获组作为分组名，无捕获组时取完整匹配）。
    var captureRegex: String = ""
    var rules: [NodeTrendGroupRule] = []

    init(id: UUID = UUID(), name: String, mode: Mode = .customRules,
         defaultKindFilter: NodeRuleKindFilter = .all,
         captureRegex: String = "", rules: [NodeTrendGroupRule] = []) {
        self.id = id
        self.name = name
        self.mode = mode
        self.defaultKindFilter = defaultKindFilter
        self.captureRegex = captureRegex
        self.rules = rules
    }

    /// 预置 4 套开箱即用方案（不硬编码私人机场名，动态适配任意 Bettbox 配置）：
    /// 1) 按机场（自动识别 `[标签]`）；2) 按国家/地区；3) 普通 vs 链式；4) 链式落地对比（自动识别 `→ 落地`）。
    static func defaultPresets() -> [NodeTrendGroupSet] {
        [
            NodeTrendGroupSet(
                id: UUID(uuidString: "A1000000-0000-0000-0000-000000000001")!,
                name: "按机场",
                mode: .regexCapture,
                defaultKindFilter: .all,
                captureRegex: #"\[([^\]]+)\]"#
            ),
            NodeTrendGroupSet(
                id: UUID(uuidString: "A1000000-0000-0000-0000-000000000002")!,
                name: "按国家/地区",
                mode: .customRules,
                defaultKindFilter: .all,
                rules: [
                    NodeTrendGroupRule(id: UUID(uuidString: "A2000000-0000-0000-0000-000000000001")!,
                                       name: "香港", regex: #"^(?:(?!→|->).)*(?:香港|🇭🇰|(?<![A-Za-z])(?:HK|Hong\s*Kong)(?![A-Za-z]))"#),
                    NodeTrendGroupRule(id: UUID(uuidString: "A2000000-0000-0000-0000-000000000002")!,
                                       name: "台湾", regex: #"^(?:(?!→|->).)*(?:台湾|台灣|🇹🇼|(?<![A-Za-z])(?:TW|Taiwan)(?![A-Za-z]))"#),
                    NodeTrendGroupRule(id: UUID(uuidString: "A2000000-0000-0000-0000-000000000003")!,
                                       name: "日本", regex: #"^(?:(?!→|->).)*(?:日本|东京|大阪|🇯🇵|(?<![A-Za-z])(?:JP|Japan)(?![A-Za-z]))"#),
                    NodeTrendGroupRule(id: UUID(uuidString: "A2000000-0000-0000-0000-000000000004")!,
                                       name: "新加坡", regex: #"^(?:(?!→|->).)*(?:新加坡|狮城|🇸🇬|(?<![A-Za-z])(?:SG|Singapore)(?![A-Za-z]))"#),
                    NodeTrendGroupRule(id: UUID(uuidString: "A2000000-0000-0000-0000-000000000005")!,
                                       name: "美国", regex: #"^(?:(?!→|->).)*(?:美国|美國|洛杉矶|硅谷|圣何塞|西雅图|🇺🇸|(?<![A-Za-z])(?:US|USA|LA)(?![A-Za-z]))"#),
                    NodeTrendGroupRule(id: UUID(uuidString: "A2000000-0000-0000-0000-000000000006")!,
                                       name: "韩国", regex: #"^(?:(?!→|->).)*(?:韩国|韓國|首尔|🇰🇷|(?<![A-Za-z])(?:KR|Korea)(?![A-Za-z]))"#),
                    NodeTrendGroupRule(id: UUID(uuidString: "A2000000-0000-0000-0000-000000000007")!,
                                       name: "欧洲", regex: #"^(?:(?!→|->).)*(?:英国|德国|法国|荷兰|欧洲|🇬🇧|🇩🇪|🇫🇷|🇳🇱|(?<![A-Za-z])(?:UK|DE|FR|NL)(?![A-Za-z]))"#),
                ]
            ),
            NodeTrendGroupSet(
                id: UUID(uuidString: "A1000000-0000-0000-0000-000000000003")!,
                name: "普通 vs 链式",
                mode: .customRules,
                defaultKindFilter: .all,
                rules: [
                    NodeTrendGroupRule(id: UUID(uuidString: "A3000000-0000-0000-0000-000000000001")!,
                                       name: "普通直连", kindFilter: .directOnly),
                    NodeTrendGroupRule(id: UUID(uuidString: "A3000000-0000-0000-0000-000000000002")!,
                                       name: "链式节点", kindFilter: .chainOnly),
                ]
            ),
            NodeTrendGroupSet(
                id: UUID(uuidString: "A1000000-0000-0000-0000-000000000004")!,
                name: "链式落地对比",
                mode: .regexCapture,
                defaultKindFilter: .chainOnly,
                captureRegex: #"→\s*(.+)$"#
            ),
        ]
    }
}

struct NodeRuleCandidate: Equatable, Sendable {
    var key: NodeKey
    var isChain: Bool
    var groups: [String]
}

struct NodeTrendGroupBucket: Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var nodeKeys: Set<NodeKey>
}

struct NodeGroupTrendPoint: Identifiable, Equatable, Sendable {
    var index: Int
    var key: Int
    var label: String
    var uptimeRate: Double?
    var avgDelayMs: Int?
    var sampledNodes: Int
    var id: Int { index }
}

struct NodeGroupTrendSeries: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var matchedNodeCount: Int
    var summary: NodeEqualWeightAggregate
    var points: [NodeGroupTrendPoint]
}

enum NodeTrendGroupMatcher {
    static let maxAutoCaptureBuckets = 12

    static func validateRegex(_ pattern: String) -> String? {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            _ = try NSRegularExpression(pattern: trimmed, options: [.caseInsensitive])
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// 计算单条自定义规则命中的节点集合（供分组计算与编辑器实时命中数预览复用）。
    static func matchRule(_ rule: NodeTrendGroupRule, setKind: NodeRuleKindFilter,
                          candidates: [NodeRuleCandidate]) -> Set<NodeKey> {
        let trimmedRegex = rule.regex.trimmingCharacters(in: .whitespacesAndNewlines)
        let compiled: NSRegularExpression?
        if trimmedRegex.isEmpty {
            compiled = nil
        } else {
            guard let re = try? NSRegularExpression(pattern: trimmedRegex, options: [.caseInsensitive]) else {
                // 正则语法非法时不退化为全匹配
                if rule.bettboxGroups.isEmpty && rule.explicitNodes.isEmpty { return [] }
                compiled = nil
                return matchWithoutRegex(rule: rule, setKind: setKind, candidates: candidates)
            }
            compiled = re
        }
        let hasMatcher = (compiled != nil) || !rule.bettboxGroups.isEmpty || !rule.explicitNodes.isEmpty
        let groupSet = Set(rule.bettboxGroups)
        let explicitSet = Set(rule.explicitNodes)

        var matched = Set<NodeKey>()
        for c in candidates {
            guard setKind.matches(isChain: c.isChain), rule.kindFilter.matches(isChain: c.isChain) else { continue }
            if !hasMatcher {
                matched.insert(c.key)
                continue
            }
            if !explicitSet.isEmpty && explicitSet.contains(c.key.name) {
                matched.insert(c.key)
                continue
            }
            if !groupSet.isEmpty && c.groups.contains(where: { groupSet.contains($0) }) {
                matched.insert(c.key)
                continue
            }
            if let re = compiled {
                let ns = c.key.name as NSString
                if re.firstMatch(in: c.key.name, range: NSRange(location: 0, length: ns.length)) != nil {
                    matched.insert(c.key)
                }
            }
        }
        return matched
    }

    private static func matchWithoutRegex(rule: NodeTrendGroupRule, setKind: NodeRuleKindFilter,
                                          candidates: [NodeRuleCandidate]) -> Set<NodeKey> {
        let groupSet = Set(rule.bettboxGroups)
        let explicitSet = Set(rule.explicitNodes)
        var matched = Set<NodeKey>()
        for c in candidates {
            guard setKind.matches(isChain: c.isChain), rule.kindFilter.matches(isChain: c.isChain) else { continue }
            if (!explicitSet.isEmpty && explicitSet.contains(c.key.name)) ||
               (!groupSet.isEmpty && c.groups.contains(where: { groupSet.contains($0) })) {
                matched.insert(c.key)
            }
        }
        return matched
    }

    static func resolveBuckets(set: NodeTrendGroupSet, kindOverride: NodeRuleKindFilter? = nil,
                               candidates: [NodeRuleCandidate]) -> [NodeTrendGroupBucket] {
        let effectiveKind = kindOverride ?? set.defaultKindFilter
        switch set.mode {
        case .regexCapture:
            let trimmed = set.captureRegex.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let re = try? NSRegularExpression(pattern: trimmed, options: [.caseInsensitive]) else {
                return []
            }
            var map: [String: Set<NodeKey>] = [:]
            for c in candidates where effectiveKind.matches(isChain: c.isChain) {
                let ns = c.key.name as NSString
                guard let m = re.firstMatch(in: c.key.name, range: NSRange(location: 0, length: ns.length)) else { continue }
                let capRange = (m.numberOfRanges > 1 && m.range(at: 1).location != NSNotFound) ? m.range(at: 1) : m.range(at: 0)
                guard capRange.location != NSNotFound else { continue }
                let label = ns.substring(with: capRange).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !label.isEmpty else { continue }
                map[label, default: []].insert(c.key)
            }
            return map.sorted {
                if $0.value.count != $1.value.count { return $0.value.count > $1.value.count }
                return $0.key < $1.key
            }
            .prefix(maxAutoCaptureBuckets)
            .map { NodeTrendGroupBucket(id: "cap:\($0.key)", name: $0.key, nodeKeys: $0.value) }

        case .customRules:
            var out: [NodeTrendGroupBucket] = []
            for rule in set.rules {
                let title = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { continue }
                let keys = matchRule(rule, setKind: effectiveKind, candidates: candidates)
                if !keys.isEmpty {
                    out.append(NodeTrendGroupBucket(id: "rule:\(rule.id.uuidString)", name: title, nodeKeys: keys))
                }
            }
            return out
        }
    }

    /// 按各时间槽内有样本节点等权聚合，生成各分组的「平均延时趋势」与「在线率趋势」曲线。
    static func aggregateSeries(buckets: [NodeTrendGroupBucket],
                                slotKeys: [Int],
                                labels: [String],
                                byNode: [NodeKey: [Int: NodeWindowMetrics]],
                                rangeMetrics: [NodeKey: NodeWindowMetrics]) -> [NodeGroupTrendSeries] {
        buckets.map { bucket in
            let summaryList = bucket.nodeKeys.compactMap { rangeMetrics[$0] }
            let summary = NodeEqualWeightAggregate.compute(from: summaryList)
            let points: [NodeGroupTrendPoint] = slotKeys.enumerated().map { idx, slotKey in
                var slotMetrics: [NodeWindowMetrics] = []
                for nk in bucket.nodeKeys {
                    if let m = byNode[nk]?[slotKey], m.probes > 0 {
                        slotMetrics.append(m)
                    }
                }
                let agg = NodeEqualWeightAggregate.compute(from: slotMetrics)
                let label = labels.indices.contains(idx) ? labels[idx] : ""
                return NodeGroupTrendPoint(index: idx, key: slotKey, label: label,
                                           uptimeRate: agg.avgUptimeRate, avgDelayMs: agg.avgDelayMs,
                                           sampledNodes: agg.sampledNodeCount)
            }
            return NodeGroupTrendSeries(id: bucket.id, name: bucket.name,
                                        matchedNodeCount: bucket.nodeKeys.count,
                                        summary: summary, points: points)
        }
    }
}

enum ActiveProbePlanner {
    /// 识别链式节点的落地桶名：优先提取 `→ <落地>` 后缀，否则按协议类型聚合，确保共享同一落地机的链式节点错峰。
    static func landingBucket(for entry: ProxyEntry) -> String? {
        guard entry.isChain else { return nil }
        for sep in [" → ", "->", "→"] {
            if let range = entry.name.range(of: sep, options: .backwards) {
                let tail = entry.name[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if !tail.isEmpty { return tail }
            }
        }
        return "chain:\(entry.type)"
    }

    /// 展开候选组批量主动探测目标：自动过滤当前配置不存在的项，默认联动纳入链式节点的 `dialer-proxy` 前置叶节点（含 `⛓` 中转节点），并按落地桶交错排布。
    static func plan(topology: NodeTopology, scope: NodeProbeScope,
                     includeChainUpstreams: Bool = true) -> [ActiveProbeTarget] {
        var selectedKeys = Set<NodeKey>()
        for groupName in scope.groups {
            if let g = topology.groupsByName[groupName] {
                selectedKeys.formUnion(g.resolvedLeaves)
            }
        }
        for nodeName in scope.nodes {
            if let key = topology.leafByName[nodeName] {
                selectedKeys.insert(key)
            }
        }
        if includeChainUpstreams {
            var frontier = Array(selectedKeys.filter(\.isChain))
            while let key = frontier.popLast() {
                if let upstreamKey = topology.resolveDialer(for: key).upstreamLeaf,
                   topology.leaves[upstreamKey] != nil,
                   selectedKeys.insert(upstreamKey).inserted,
                   upstreamKey.isChain {
                    frontier.append(upstreamKey)
                }
            }
        }

        let entries = selectedKeys.compactMap { topology.leaves[$0] }
            .sorted { $0.name < $1.name || ($0.name == $1.name && $0.dialerProxy < $1.dialerProxy) }

        var buckets: [String: [ActiveProbeTarget]] = [:]
        for e in entries {
            let bucket = landingBucket(for: e)
            let bucketKey = bucket ?? "\u{00}direct:\(e.name)"
            buckets[bucketKey, default: []].append(ActiveProbeTarget(key: e.key, nodeType: e.type, landingBucket: bucket))
        }
        let sortedKeys = buckets.keys.sorted()
        var result: [ActiveProbeTarget] = []
        result.reserveCapacity(entries.count)
        var index = 0
        while result.count < entries.count {
            var added = false
            for k in sortedKeys {
                if let list = buckets[k], index < list.count {
                    result.append(list[index])
                    added = true
                }
            }
            if !added { break }
            index += 1
        }
        return result
    }

    /// 展开选定分组当前出口的穿透映射（跳过当前配置不存在或指向 DIRECT/REJECT 的分组）。
    static func planWatchedGroups(topology: NodeTopology, watchedGroups: [String]) -> [WatchedGroupPlanItem] {
        var seen = Set<String>()
        var result: [WatchedGroupPlanItem] = []
        for g in watchedGroups where seen.insert(g).inserted {
            if let leaf = topology.resolveCurrentLeaf(ofGroup: g) {
                result.append(WatchedGroupPlanItem(groupName: g, leaf: leaf))
            }
        }
        return result
    }
}
