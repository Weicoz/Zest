//
//  NodeMonitorModel.swift
//  Zest
//
//  网络窗口「节点」页的数据模型（运行在查看器进程）：
//  - 在后台串行队列从 HistoryStore(migrate: false) 只读查询节点 1d/7d/30d（支持按来源筛选）与分组出口通道统计；
//  - 在后台按指纹缓存 config.yaml / config.json 解析并拉取本机 GET /proxies；
//  - 严格三态（在线/离线/未测），不将 Mihomo 默认 alive=true 误标为在线。
//

import Foundation

enum NodeMonitorStatus: Equatable {
    case starting
    case available
    case notRunning
    case configMissing
    case nonLocalController
    case authFailed
    case decodeFailed
}

struct NodeDisplayRow: Identifiable, Equatable {
    var key: NodeKey
    var nodeType: String
    var inCurrentConfig: Bool
    var groups: [String]
    var liveState: NodeLiveState
    var latestDelayMs: Int?
    var latestTsMs: Int64?
    var day1: NodeWindowMetrics
    var day7: NodeWindowMetrics
    var day30: NodeWindowMetrics
    var hourly24: [NodeHourPoint]
    var dialerResolution: DialerResolution

    var id: NodeKey { key }
    var name: String { key.name }
    var dialer: String { key.dialer }
    var isChain: Bool { key.isChain }

    func metrics(for range: NodeStatsRange) -> NodeWindowMetrics {
        switch range {
        case .day1: return day1
        case .day7: return day7
        case .day30: return day30
        }
    }
}

struct NodeTrendPoint: Identifiable, Equatable {
    var index: Int
    var key: Int
    var label: String
    var uptimeRate: Double?
    var avgDelayMs: Int?
    var probes: Int
    var ok: Int
    var id: Int { index }
}

struct NodeDetailComparison: Equatable {
    var primaryKey: NodeKey
    var primarySeries: [NodeTrendPoint] = []
    var upstreamResolution: DialerResolution = .direct
    var upstreamRow: NodeDisplayRow?
    var upstreamSeries: [NodeTrendPoint] = []
}

private struct NodeRefreshBundle: Sendable {
    var status: NodeMonitorStatus
    var profile: BettboxProfileInfo
    var topology: NodeTopology
    var summaries: [NodeKey: NodeSummaryRecord]
    var groupWatches: [String: GroupWatchSummaryRecord]
    var emptyHours: [NodeHourPoint]
}

/// 独立串行队列上的只读库与配置缓存封装。
struct NodeAllTrendGrid: Equatable, Sendable {
    var range: NodeStatsRange = .day1
    var slotKeys: [Int] = []
    var labels: [String] = []
    var byNode: [NodeKey: [Int: NodeWindowMetrics]] = [:]
}

private final class NodeHistoryReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.zest.nodehistory.reader", qos: .utility)
    private var store: HistoryStore?
    private var cachedFingerprint = ""
    private var cachedProfile = BettboxProfileInfo.fallback
    private var cachedClient: Result<BettboxClient, BettboxConfigError>?

    func currentFingerprint() async -> String {
        await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: BettboxClient.configFingerprint()) }
        }
    }

    func fetchBundle(sourceFilter: NodeSourceFilter, now: Date, calendar: Calendar) async -> NodeRefreshBundle? {
        let (profile, clientResult, summaries, groupWatches, emptyHours):
            (BettboxProfileInfo, Result<BettboxClient, BettboxConfigError>, [NodeKey: NodeSummaryRecord], [String: GroupWatchSummaryRecord], [NodeHourPoint]) =
            await withCheckedContinuation { cont in
                queue.async { [self] in
                    let fp = BettboxClient.configFingerprint()
                    if fp != cachedFingerprint || cachedClient == nil {
                        cachedFingerprint = fp
                        cachedProfile = BettboxClient.loadProfile()
                        cachedClient = BettboxClient.load()
                    }
                    if store == nil { store = HistoryStore(migrate: false, calendar: calendar) }
                    let sum = store?.nodeSummaries(sourceFilter: sourceFilter, now: now, calendar: calendar) ?? [:]
                    let gw = store?.groupWatchSummaries(profileId: cachedProfile.id, now: now, calendar: calendar) ?? [:]
                    let hours = Self.emptyHourSlots(count: 24, now: now, calendar: calendar)
                    cont.resume(returning: (cachedProfile, cachedClient ?? .failure(.missing), sum, gw, hours))
                }
            }

        var status = NodeMonitorStatus.starting
        var payload = BettboxProxiesPayload()

        switch clientResult {
        case .failure(.missing):
            status = .configMissing
        case .failure(.nonLocal):
            status = .nonLocalController
        case .success(let client):
            switch await client.fetchProxies() {
            case .available(let p):
                status = .available
                payload = p
            case .notRunning: status = .notRunning
            case .configMissing: status = .configMissing
            case .nonLocalController: status = .nonLocalController
            case .authFailed: status = .authFailed
            case .decodeFailed: status = .decodeFailed
            case .cancelled: return nil
            }
        }

        let topology: NodeTopology = await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: NodeTopology(payload: payload)) }
        }
        return NodeRefreshBundle(status: status, profile: profile, topology: topology,
                                 summaries: summaries, groupWatches: groupWatches, emptyHours: emptyHours)
    }

    func readAllTrendGrid(range: NodeStatsRange, sourceFilter: NodeSourceFilter,
                          now: Date, calendar: Calendar) async -> NodeAllTrendGrid {
        await withCheckedContinuation { cont in
            queue.async { [self] in
                if store == nil { store = HistoryStore(migrate: false, calendar: calendar) }
                guard let store else { cont.resume(returning: NodeAllTrendGrid(range: range)); return }
                switch range {
                case .day1:
                    let res = store.nodeAllHourlySeries(hours: 24, sourceFilter: sourceFilter, now: now, calendar: calendar)
                    let labels = res.keys.map { String(format: "%02d", $0 % 100) }
                    cont.resume(returning: NodeAllTrendGrid(range: range, slotKeys: res.keys, labels: labels, byNode: res.byNode))
                case .day7:
                    let res = store.nodeAllDailySeries(days: 7, sourceFilter: sourceFilter, now: now, calendar: calendar)
                    let labels = res.keys.map { String(format: "%02d/%02d", ($0 / 100) % 100, $0 % 100) }
                    cont.resume(returning: NodeAllTrendGrid(range: range, slotKeys: res.keys, labels: labels, byNode: res.byNode))
                case .day30:
                    let res = store.nodeAllDailySeries(days: 30, sourceFilter: sourceFilter, now: now, calendar: calendar)
                    let labels = res.keys.map { String(format: "%02d/%02d", ($0 / 100) % 100, $0 % 100) }
                    cont.resume(returning: NodeAllTrendGrid(range: range, slotKeys: res.keys, labels: labels, byNode: res.byNode))
                }
            }
        }
    }

    func readTrend(for key: NodeKey, upstream: NodeKey?, range: NodeStatsRange,
                   sourceFilter: NodeSourceFilter, now: Date,
                   calendar: Calendar) async -> (primary: [NodeTrendPoint], upstream: [NodeTrendPoint]) {
        await withCheckedContinuation { cont in
            queue.async { [self] in
                if store == nil { store = HistoryStore(migrate: false, calendar: calendar) }
                guard let store else { cont.resume(returning: ([], [])); return }
                let p = Self.buildTrend(store: store, key: key, range: range, sourceFilter: sourceFilter, now: now, calendar: calendar)
                let u = upstream.map { Self.buildTrend(store: store, key: $0, range: range, sourceFilter: sourceFilter, now: now, calendar: calendar) } ?? []
                cont.resume(returning: (p, u))
            }
        }
    }

    private static func emptyHourSlots(count: Int, now: Date, calendar: Calendar) -> [NodeHourPoint] {
        var seen = Set<Int>()
        var keys: [Int] = []
        keys.reserveCapacity(count)
        var back = 0
        while keys.count < count && back < count + 4 {
            if let d = calendar.date(byAdding: .hour, value: -back, to: now) {
                let k = DayRange.hourKey(of: d, calendar: calendar)
                if seen.insert(k).inserted { keys.append(k) }
            }
            back += 1
        }
        return keys.reversed().map { NodeHourPoint(hour: $0, metrics: NodeWindowMetrics()) }
    }

    private static func buildTrend(store: HistoryStore, key: NodeKey, range: NodeStatsRange,
                                   sourceFilter: NodeSourceFilter, now: Date, calendar: Calendar) -> [NodeTrendPoint] {
        switch range {
        case .day1:
            return store.nodeHourlySeries(key: key, hours: 24, sourceFilter: sourceFilter, now: now, calendar: calendar)
                .enumerated().map { idx, pt in
                    NodeTrendPoint(index: idx, key: pt.hour, label: String(format: "%02d", pt.hour % 100),
                                   uptimeRate: pt.metrics.uptimeRate, avgDelayMs: pt.metrics.avgDelayMs,
                                   probes: pt.metrics.probes, ok: pt.metrics.ok)
                }
        case .day7:
            return store.nodeDailySeries(key: key, days: 7, sourceFilter: sourceFilter, now: now, calendar: calendar)
                .enumerated().map { idx, pt in
                    NodeTrendPoint(index: idx, key: pt.day,
                                   label: String(format: "%02d/%02d", (pt.day / 100) % 100, pt.day % 100),
                                   uptimeRate: pt.metrics.uptimeRate, avgDelayMs: pt.metrics.avgDelayMs,
                                   probes: pt.metrics.probes, ok: pt.metrics.ok)
                }
        case .day30:
            return store.nodeDailySeries(key: key, days: 30, sourceFilter: sourceFilter, now: now, calendar: calendar)
                .enumerated().map { idx, pt in
                    NodeTrendPoint(index: idx, key: pt.day,
                                   label: String(format: "%02d/%02d", (pt.day / 100) % 100, pt.day % 100),
                                   uptimeRate: pt.metrics.uptimeRate, avgDelayMs: pt.metrics.avgDelayMs,
                                   probes: pt.metrics.probes, ok: pt.metrics.ok)
                }
        }
    }
}

@MainActor
final class NodeMonitorModel: ObservableObject {
    @Published private(set) var status: NodeMonitorStatus = .starting
    @Published private(set) var profile: BettboxProfileInfo = .fallback
    @Published private(set) var topology = NodeTopology(payload: BettboxProxiesPayload())
    @Published private(set) var rows: [NodeDisplayRow] = []
    @Published private(set) var rowsByKey: [NodeKey: NodeDisplayRow] = [:]
    @Published private(set) var groupWatches: [String: GroupWatchSummaryRecord] = [:]
    @Published private(set) var emptyHours24: [NodeHourPoint] = []
    @Published private(set) var lastActiveRun: NodeActiveProbeRunInfo?
    @Published private(set) var detail: NodeDetailComparison?
    @Published private(set) var sourceFilter: NodeSourceFilter = .all
    @Published private(set) var liveProgress: NodeProbeLiveProgress?
    @Published private(set) var trendGrid = NodeAllTrendGrid()

    private let reader = NodeHistoryReader()
    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var trendGridTask: Task<Void, Never>?
    private var progressClearTask: Task<Void, Never>?
    private var progressObserver: NSObjectProtocol?
    private var lastObservedFlushed = 0
    private var lastFingerprint = ""
    private var selectedKey: NodeKey?
    private var selectedRange: NodeStatsRange = .day1
    private var refreshSerial = 0
    private var detailSerial = 0
    private var trendGridSerial = 0

    deinit {
        if let obs = progressObserver {
            DistributedNotificationCenter.default().removeObserver(obs)
        }
    }

    func start() {
        if progressObserver == nil {
            progressObserver = DistributedNotificationCenter.default().addObserver(
                forName: NodeMonitorService.probeProgressNotification, object: nil, queue: .main
            ) { [weak self] note in
                guard let raw = note.userInfo?["progress"] as? String,
                      let data = raw.data(using: .utf8),
                      let progress = try? JSONDecoder().decode(NodeProbeLiveProgress.self, from: data) else { return }
                MainActor.assumeIsolated {
                    self?.handleLiveProgress(progress)
                }
            }
            DistributedNotificationCenter.default().postNotificationName(
                NodeMonitorService.queryProbeProgressNotification, object: nil, userInfo: nil, deliverImmediately: true
            )
        }
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                let fp = await self.reader.currentFingerprint()
                if tick % 2 == 0 || fp != self.lastFingerprint {
                    self.lastFingerprint = fp
                    await self.refreshNow()
                }
                tick += 1
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stop() {
        if let obs = progressObserver {
            DistributedNotificationCenter.default().removeObserver(obs)
            progressObserver = nil
        }
        progressClearTask?.cancel()
        progressClearTask = nil
        liveProgress = nil
        lastObservedFlushed = 0
        pollTask?.cancel()
        pollTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshSerial += 1
        detailTask?.cancel()
        detailTask = nil
        detailSerial += 1
        trendGridTask?.cancel()
        trendGridTask = nil
        trendGridSerial += 1
        selectedKey = nil
        detail = nil
    }

    func setSourceFilter(_ filter: NodeSourceFilter) {
        guard filter != sourceFilter else { return }
        sourceFilter = filter
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.refreshNow()
        }
    }

    func triggerActiveProbe(settings: AppSettings, adHocGroup: String? = nil) {
        // 乐观立即呈现“正在校验本机网络…”，点击 0ms 即有动态反馈
        progressClearTask?.cancel()
        progressClearTask = nil
        lastObservedFlushed = 0
        liveProgress = NodeProbeLiveProgress(
            runId: 0, phase: .checkingDirect, total: 0, completed: 0,
            online: 0, offline: 0, activeNodes: [], recentResults: [],
            flushedSamples: 0, updatedAt: Date().timeIntervalSince1970
        )
        // 兜底保护：若后台服务未响应 IPC，15 秒后自动清除乐观占位态，避免界面假死。
        progressClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled, let self, self.liveProgress?.runId == 0 else { return }
            self.liveProgress = nil
        }
        var info = settings.nodeProbeUserInfo() ?? [:]
        if let adHocGroup, !adHocGroup.isEmpty {
            info["adHocGroup"] = adHocGroup
        }
        DistributedNotificationCenter.default().postNotificationName(
            NodeMonitorService.triggerActiveProbeNotification, object: nil,
            userInfo: info, deliverImmediately: true)
    }

    func cancelActiveProbe() {
        DistributedNotificationCenter.default().postNotificationName(
            NodeMonitorService.cancelActiveProbeNotification, object: nil,
            userInfo: nil, deliverImmediately: true)
    }

    func dismissLiveProgress() {
        progressClearTask?.cancel()
        progressClearTask = nil
        if liveProgress?.isRunning != true {
            liveProgress = nil
        }
    }

    private func handleLiveProgress(_ progress: NodeProbeLiveProgress) {
        // 忽略旧轮次或同轮次乱序回退/终态后迟到的在途通知（允许 runId=0 的本地乐观占位被任意真实 runId 取代）
        if let cur = liveProgress, cur.runId > 0, progress.runId > 0 {
            if progress.runId < cur.runId { return }
            if progress.runId == cur.runId {
                if !cur.isRunning && progress.isRunning { return }
                if progress.updatedAt < cur.updatedAt { return }
            }
        }
        let isNewRun = (liveProgress?.runId != progress.runId)
        liveProgress = progress

        let flushedChanged = isNewRun ? (progress.flushedSamples > 0) : (progress.flushedSamples != lastObservedFlushed)
        if flushedChanged || !progress.isRunning {
            lastObservedFlushed = progress.flushedSamples
            refreshTask?.cancel()
            refreshTask = Task { [weak self] in
                await self?.refreshNow()
            }
        }

        progressClearTask?.cancel()
        progressClearTask = nil
        if !progress.isRunning {
            let endedRunId = progress.runId
            progressClearTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled, let self,
                      let cur = self.liveProgress, !cur.isRunning, cur.runId == endedRunId else { return }
                self.liveProgress = nil
            }
        }
    }

    func select(key: NodeKey?, range: NodeStatsRange) {
        let rangeChanged = (selectedRange != range)
        selectedKey = key
        selectedRange = range
        reloadDetail()
        if rangeChanged {
            reloadTrendGrid()
        }
    }

    func reloadTrendGrid() {
        trendGridTask?.cancel()
        trendGridSerial += 1
        let serial = trendGridSerial
        let range = selectedRange
        let filter = sourceFilter
        let now = Date()
        let calendar = Calendar.current
        trendGridTask = Task { [weak self] in
            guard let self else { return }
            let grid = await self.reader.readAllTrendGrid(range: range, sourceFilter: filter, now: now, calendar: calendar)
            guard !Task.isCancelled, serial == self.trendGridSerial, filter == self.sourceFilter, range == self.selectedRange else { return }
            self.trendGrid = grid
        }
    }

    func refreshNow() async {
        refreshSerial += 1
        let serial = refreshSerial
        let now = Date()
        let nowMs = Int64((now.timeIntervalSince1970 * 1000.0).rounded())
        let calendar = Calendar.current
        let activeFilter = sourceFilter
        let clearedAtMs = max(Int64(UserDefaults.standard.object(forKey: NodeMonitorService.clearedAtMsDefaultsKey) as? Int64
                                    ?? Int64(UserDefaults.standard.integer(forKey: NodeMonitorService.clearedAtMsDefaultsKey))), 0)
        guard let bundle = await reader.fetchBundle(sourceFilter: activeFilter, now: now, calendar: calendar) else { return }
        guard !Task.isCancelled, serial == refreshSerial, activeFilter == sourceFilter else { return }

        var allKeys = Set(bundle.summaries.keys)
        allKeys.formUnion(bundle.topology.leaves.keys)

        var built: [NodeDisplayRow] = []
        built.reserveCapacity(allKeys.count)
        var byKey: [NodeKey: NodeDisplayRow] = [:]
        byKey.reserveCapacity(allKeys.count)

        for key in allKeys {
            let live = bundle.topology.leaves[key]
            let sum = bundle.summaries[key]
            let inCurrent = (live != nil)

            // 严格三态：仅以真实探测记录或受 clearedAtMs 约束的统一兜底为准，绝不采信 Mihomo 默认 alive=true。
            var liveState: NodeLiveState = .untested
            var latestDelay: Int?
            var latestTs: Int64?

            if let latest = sum?.latest {
                liveState = latest.ok ? .online : .offline
                latestDelay = latest.ok ? latest.delayMs : nil
                latestTs = latest.tsMs
            } else if activeFilter == .all, let live,
                      let fb = PassiveHistoryExtractor.latestValidFallback(for: live, nowMs: nowMs, clearedAtMs: clearedAtMs) {
                liveState = fb.ok ? .online : .offline
                latestDelay = fb.ok ? fb.delayMs : nil
                latestTs = fb.tsMs
            }

            let row = NodeDisplayRow(
                key: key,
                nodeType: live?.type ?? sum?.nodeType ?? "",
                inCurrentConfig: inCurrent,
                groups: bundle.topology.leafGroups[key] ?? [],
                liveState: liveState,
                latestDelayMs: latestDelay,
                latestTsMs: latestTs,
                day1: sum?.day1 ?? NodeWindowMetrics(),
                day7: sum?.day7 ?? NodeWindowMetrics(),
                day30: sum?.day30 ?? NodeWindowMetrics(),
                hourly24: sum?.hourly24 ?? bundle.emptyHours,
                dialerResolution: inCurrent ? bundle.topology.resolveDialer(for: key) : (key.isChain ? .unresolved(key.dialer) : .direct)
            )
            built.append(row)
            byKey[key] = row
        }

        self.status = bundle.status
        self.profile = bundle.profile
        self.topology = bundle.topology
        self.rows = built
        self.rowsByKey = byKey
        self.groupWatches = bundle.groupWatches
        self.emptyHours24 = bundle.emptyHours
        if let data = UserDefaults.standard.data(forKey: NodeMonitorService.lastActiveRunDefaultsKey),
           let info = try? JSONDecoder().decode(NodeActiveProbeRunInfo.self, from: data) {
            self.lastActiveRun = info
        } else {
            self.lastActiveRun = nil
        }

        let targetRange = selectedRange
        trendGridTask?.cancel()
        trendGridSerial += 1
        let gridSerial = trendGridSerial
        let grid = await reader.readAllTrendGrid(range: targetRange, sourceFilter: activeFilter, now: now, calendar: calendar)
        guard !Task.isCancelled, serial == refreshSerial, gridSerial == trendGridSerial,
              targetRange == selectedRange, activeFilter == sourceFilter else { return }
        self.trendGrid = grid

        if selectedKey != nil {
            reloadDetail()
        }
    }

    private func reloadDetail() {
        detailTask?.cancel()
        guard let key = selectedKey else {
            detail = nil
            return
        }
        detailSerial += 1
        let serial = detailSerial
        let range = selectedRange
        let filter = sourceFilter
        let resolution = rowsByKey[key]?.dialerResolution ?? .direct
        let upstreamKey = resolution.upstreamLeaf
        let upstreamRow = upstreamKey.flatMap { rowsByKey[$0] }
        let now = Date()
        let calendar = Calendar.current

        detailTask = Task { [weak self] in
            guard let self else { return }
            let pair = await self.reader.readTrend(for: key, upstream: upstreamKey, range: range,
                                                   sourceFilter: filter, now: now, calendar: calendar)
            guard !Task.isCancelled, serial == self.detailSerial else { return }
            self.detail = NodeDetailComparison(
                primaryKey: key,
                primarySeries: pair.primary,
                upstreamResolution: resolution,
                upstreamRow: upstreamRow,
                upstreamSeries: pair.upstream
            )
        }
    }
}
