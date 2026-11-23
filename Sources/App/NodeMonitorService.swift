//
//  NodeMonitorService.swift
//  Zest
//
//  主进程的 Bettbox 节点与分组出口连通监测服务（极致低资源版）：
//  - 配置热切换：使用内核 DispatchSourceFileSystemObject 监听 Bettbox 配置目录，无 10 秒空转轮询；
//  - 单一定时器：仅 1 个 60 秒低频合并唤醒定时器（leeway 5s），休眠期间完全取消，零 CPU 唤醒；
//  - 轨道 A（被动清洗）：60s 读本机 /proxies，执行 3900ms 超时边界清洗 + 30s 冷却折叠 + 15s 风暴门控 + 重载 30s 抑制；
//  - 分组出口通道监测：按当前配置选定的 watchedGroups 每 5 分钟穿透检测实际出站叶节点（同叶合并只测 1 次），
//    服务视角连续计入分组 1d/7d/30d，连续 2 次超时（且 DIRECT 正常）发送 1 条 macOS 通知；
//  - 轨道 B（候选组批量主动探测）：默认关闭；开启后自动联动链式前置节点，并发 ≤ 4 且同落地桶串行错峰。
//

import Darwin
import Foundation
import UserNotifications

struct NodeActiveProbeRunInfo: Codable, Equatable, Sendable {
    var finishedAt: TimeInterval
    var profileId: String
    var probed: Int
    var online: Int
    var skippedReason: String?
}

struct NodePanelSummary: Equatable, Sendable {
    var status: NodeMonitorStatus = .starting
    var profileName: String = ""
    var totalNodes: Int = 0
    var onlineNodes: Int = 0
    var offlineNodes: Int = 0
    var untestedNodes: Int = 0
    var chainNodes: Int = 0
    var day1 = NodeEqualWeightAggregate()
    var day7 = NodeEqualWeightAggregate()
    var day30 = NodeEqualWeightAggregate()
    var watchedGroups: [GroupWatchSummaryRecord] = []
    var activeEnabled: Bool = false
    var activeGroups: Int = 0
    var lastActiveRun: NodeActiveProbeRunInfo?

    var hasAnyHistory: Bool {
        day1.sampledNodeCount > 0 || day7.sampledNodeCount > 0 || day30.sampledNodeCount > 0 || !watchedGroups.isEmpty
    }
}

final class NodeSummaryStore: ObservableObject {
    @Published private(set) var summary = NodePanelSummary()

    func update(_ next: NodePanelSummary) {
        if summary != next { summary = next }
    }
}

final class NodeMonitorService: @unchecked Sendable {
    static let triggerActiveProbeNotification = Notification.Name("app.zest.monitor.triggerNodeProbe")
    static let cancelActiveProbeNotification = Notification.Name("app.zest.monitor.cancelNodeProbe")
    static let probeProgressNotification = Notification.Name("app.zest.monitor.nodeProbeProgress")
    static let queryProbeProgressNotification = Notification.Name("app.zest.monitor.queryNodeProbeProgress")
    static let lastActiveRunDefaultsKey = "nodeMonitorLastActiveRun"
    static let clearedAtMsDefaultsKey = "nodeMonitorClearedAtMs"

    /// 唯一后台节拍：每 60 秒合并唤醒一次（带 5 秒 leeway 供 macOS 合并系统唤醒）。
    static let baseTimerIntervalSeconds = 60
    static let reloadStormSuppressSeconds: TimeInterval = 30
    static let maxConcurrency = 4
    static let interProbeDelayNs: UInt64 = 120_000_000
    static let activeDedupBufferMs: Int64 = 5_000
    static let midRoundOfflineCheckThreshold = 4
    static let groupOfflineNotifyThreshold = 2

    struct Config: Equatable {
        var activeEnabled: Bool = false
        var intervalMinutes: Int = 10
        var scopes: [String: NodeProbeScope] = [:]
        var groupAlertEnabled: Bool = true
        var timeoutMs: Int = BettboxClient.defaultProbeTimeoutMs
        var probeURL: String = BettboxClient.defaultProbeURL
        /// 分组当前出口监测周期（分钟），与 60 秒主节拍共用。
        var watchIntervalMinutes: Int = AppSettings.defaultNodeGroupWatchIntervalMinutes
        /// 读取哪一个本机客户端的配置（节点监测与链路监测共用）。
        var source: ProxyClientSource = .bettbox
        /// `source == .custom` 时用户指定的本机 config.yaml 路径。
        var customConfigPath: String = ""
    }

    private let queue = DispatchQueue(label: "app.zest.nodemonitor", qos: .utility)
    private let calendar: Calendar
    private var timer: DispatchSourceTimer?
    private var dirMonitor: DispatchSourceFileSystemObject?
    private var configChangeDebounce: DispatchWorkItem?

    private var store: HistoryStore?
    private var storePreloaded = false
    private var lastSeenMs: [NodeKey: Int64] = [:]
    private var clearedAtMs: Int64
    private var config = Config()

    private var enabled = false
    private var paused = false
    private var panelVisible = false
    private var generation = 0
    private var activeRunID = 0
    private var watchRunID = 0
    private var lastConfigFingerprint = ""
    private var cachedProfile = BettboxProfileInfo.fallback
    private var cachedClient: Result<BettboxClient, BettboxConfigError>?
    private var watchedDirectoryPath: String?

    private var reloadSuppressUntil: Date = .distantPast
    private var lastPassiveAt: Date = .distantPast
    private var lastWatchAt: Date = .distantPast
    private var lastActiveAt: Date = .distantPast
    private var nextActiveAllowedAt: Date = .distantPast

    private var passiveInFlight = false
    private var watchInFlight = false
    private var activeInFlight = false
    private var pendingManualWatch = false
    private var pendingManualBulk = false
    private var pendingAdHocGroup: String?
    private var watchTask: Task<Void, Never>?
    private var activeTask: Task<Void, Never>?
    private var lastTopology: NodeTopology?
    private var progressRunSeq = 0
    private var latestProgress: NodeProbeLiveProgress?

    /// 摘要更新回调（仅在菜单栏弹窗处于可见状态或按需刷新时推送，平时关闭零 UI 推送）。
    var onSummary: ((NodePanelSummary) -> Void)?

    init(calendar: Calendar = .autoupdatingCurrent) {
        self.calendar = calendar
        let saved = Int64(UserDefaults.standard.object(forKey: Self.clearedAtMsDefaultsKey) as? Int64
                          ?? Int64(UserDefaults.standard.integer(forKey: Self.clearedAtMsDefaultsKey)))
        self.clearedAtMs = max(saved, 0)
    }

    deinit {
        cancelTimer()
        stopDirectoryWatcher()
    }

    func updateConfig(activeEnabled: Bool, intervalMinutes: Int, scopes: [String: NodeProbeScope],
                      groupAlertEnabled: Bool = true,
                      watchIntervalMinutes: Int = AppSettings.defaultNodeGroupWatchIntervalMinutes,
                      source: ProxyClientSource = .bettbox,
                      customConfigPath: String = "") {
        queue.async { [self] in
            let next = Config(activeEnabled: activeEnabled,
                              intervalMinutes: max(intervalMinutes, 1),
                              scopes: scopes,
                              groupAlertEnabled: groupAlertEnabled,
                              timeoutMs: BettboxClient.defaultProbeTimeoutMs,
                              probeURL: BettboxClient.defaultProbeURL,
                              watchIntervalMinutes: max(watchIntervalMinutes, 1),
                              source: source,
                              customConfigPath: customConfigPath)
            let wasEnabled = config.activeEnabled
            let oldScopes = config.scopes
            let oldWatchInterval = config.watchIntervalMinutes
            let oldSource = config.source
            let oldCustomPath = config.customConfigPath
            config = next

            // 配置源或自定义路径变化：配置目录可能换了，重建 kqueue 监听并立刻重解析配置。
            if oldSource != next.source || oldCustomPath != next.customConfigPath {
                stopDirectoryWatcher()
                lastConfigFingerprint = ""
                refreshConfigCacheIfNeeded()
                if enabled { startDirectoryWatcher() }
            }

            let curProfileId = cachedProfile.id
            let oldWatched = oldScopes[curProfileId]?.watchedGroups ?? []
            let newWatched = next.scopes[curProfileId]?.watchedGroups ?? []
            let oldBulk = oldScopes[curProfileId]
            let newBulk = next.scopes[curProfileId]

            if wasEnabled && !next.activeEnabled {
                pendingManualBulk = false
                cancelActiveTask()
            }
            if newWatched != oldWatched {
                pendingManualWatch = false
                cancelWatchTask()
                if enabled && !paused && !newWatched.isEmpty {
                    lastWatchAt = .distantPast
                }
            }
            if next.activeEnabled && enabled && !paused &&
                (!wasEnabled || oldBulk?.groups != newBulk?.groups || oldBulk?.nodes != newBulk?.nodes) {
                lastActiveAt = .distantPast
            }
            if oldWatchInterval != next.watchIntervalMinutes && newWatched.isEmpty == false {
                lastWatchAt = .distantPast
            }
            if enabled && !paused {
                tick()
            }
        }
    }

    func start() {
        queue.async { [self] in
            guard !enabled else { return }
            enabled = true
            startDirectoryWatcher()
            scheduleTimer()
            tick()
        }
    }

    func stop() {
        queue.async { [self] in
            enabled = false
            cancelTimer()
            stopDirectoryWatcher()
            generation += 1
            pendingManualWatch = false
            pendingManualBulk = false
            pendingAdHocGroup = nil
            cancelWatchTask()
            cancelActiveTask()
        }
    }

    /// 屏幕/系统休眠时完全取消定时器与在途任务（休眠期 0 唤醒）；唤醒后给系统网络留出 5 秒恢复缓冲。
    func setPaused(_ paused: Bool) {
        queue.async { [self] in
            guard self.paused != paused else { return }
            self.paused = paused
            if paused {
                cancelTimer()
                generation += 1
                pendingManualWatch = false
                pendingManualBulk = false
                pendingAdHocGroup = nil
                cancelWatchTask()
                cancelActiveTask()
            } else if enabled {
                nextActiveAllowedAt = Date().addingTimeInterval(5)
                lastPassiveAt = .distantPast
                scheduleTimer()
                tick()
            }
        }
    }

    func setPanelVisible(_ visible: Bool) {
        queue.async { [self] in
            let becameVisible = visible && !panelVisible
            panelVisible = visible
            if becameVisible {
                performPanelSummaryRefresh()
            }
        }
    }

    func clearSync() {
        queue.sync {
            generation += 1
            pendingManualWatch = false
            pendingManualBulk = false
            pendingAdHocGroup = nil
            cancelWatchTask()
            cancelActiveTask()
            lastSeenMs.removeAll()
            let nowMs = Int64((Date().timeIntervalSince1970 * 1000.0).rounded())
            clearedAtMs = nowMs
            UserDefaults.standard.set(nowMs, forKey: Self.clearedAtMsDefaultsKey)
            UserDefaults.standard.removeObject(forKey: Self.lastActiveRunDefaultsKey)
        }
    }

    /// 立即触发一轮探测：支持按当前配置已勾选范围（先盯住分组、后候选组全量）或指定单个策略组即时测速。
    func triggerActiveProbeNow(adHocGroup: String? = nil) {
        queue.async { [self] in
            guard enabled, !paused else { return }
            refreshConfigCacheIfNeeded()
            nextActiveAllowedAt = .distantPast
            if let g = adHocGroup, !g.isEmpty {
                pendingAdHocGroup = g
            } else {
                let scope = config.scopes[cachedProfile.id] ?? NodeProbeScope()
                if scope.hasWatchedGroups { pendingManualWatch = true }
                if !scope.isEmpty { pendingManualBulk = true }
            }
            tick()
        }
    }

    /// 用户手动停止当前正在进行的主动测速（已增量落盘的样本全部保留，并立即广播已停止状态）。
    func cancelProbesByUser() {
        queue.async { [self] in
            let hadPending = pendingManualWatch || pendingManualBulk || pendingAdHocGroup != nil
            pendingManualWatch = false
            pendingManualBulk = false
            pendingAdHocGroup = nil
            let wasRunning = watchInFlight || activeInFlight
            cancelWatchTask()
            cancelActiveTask()
            if wasRunning || hadPending || latestProgress?.isRunning == true {
                markLiveProgressCancelledIfNeeded(forceEmit: true)
                if panelVisible {
                    publishSummary(status: lastTopology != nil ? .available : .starting, topology: lastTopology, force: false)
                }
            }
        }
    }

    /// 保证任意外部取消路径（配置切换、休眠、停用、清库、用户手动停止）均将 `latestProgress` 收敛为 `.cancelled`，
    /// 维持不变量：`latestProgress?.isRunning` 严格等同于 `watchInFlight || activeInFlight`。
    private func markLiveProgressCancelledIfNeeded(forceEmit: Bool = false) {
        guard forceEmit || latestProgress?.isRunning == true else { return }
        var stopped = latestProgress ?? NodeProbeLiveProgress(
            runId: progressRunSeq, phase: .cancelled, total: 0, completed: 0,
            online: 0, offline: 0, activeNodes: [], recentResults: [],
            flushedSamples: 0, updatedAt: Date().timeIntervalSince1970
        )
        stopped.phase = .cancelled
        stopped.activeNodes = []
        stopped.updatedAt = Date().timeIntervalSince1970
        emitProgress(stopped)
    }

    /// 窗口中途打开时主动拉取当前进度（空闲或结束超过 10 秒时不广播，保持零冗余开销）。
    func rebroadcastProgress() {
        queue.async { [self] in
            guard let p = latestProgress else { return }
            if p.isRunning || (Date().timeIntervalSince1970 - p.updatedAt) <= 10 {
                emitProgress(p)
            }
        }
    }

    private func emitProgress(_ progress: NodeProbeLiveProgress) {
        latestProgress = progress
        guard let data = try? JSONEncoder().encode(progress),
              let str = String(data: data, encoding: .utf8) else { return }
        DistributedNotificationCenter.default().postNotificationName(
            Self.probeProgressNotification, object: nil,
            userInfo: ["progress": str], deliverImmediately: true
        )
    }

    /// 菜单栏弹窗打开并停留在“网络”页时按需刷新一次摘要（弹窗关闭期间不调用、零额外查询）。
    func refreshPanelSummaryNow() {
        queue.async { [self] in
            performPanelSummaryRefresh()
        }
    }

    private func performPanelSummaryRefresh() {
        refreshConfigCacheIfNeeded()
        let clientRes = cachedClient ?? BettboxClient.load(source: config.source, customPath: config.customConfigPath)
        switch clientRes {
        case .failure(.missing):
            publishSummary(status: .configMissing, topology: nil, force: true)
            return
        case .failure(.nonLocal):
            publishSummary(status: .nonLocalController, topology: nil, force: true)
            return
        case .success(let client):
            if let lastTopology {
                publishSummary(status: .available, topology: lastTopology, force: true)
            }
            Task { [weak self] in
                let result = await client.fetchProxies()
                guard let self else { return }
                self.queue.async {
                    switch result {
                    case .available(let payload):
                        let topo = NodeTopology(payload: payload, groupOrder: client.groupOrder)
                        self.lastTopology = topo
                        self.publishSummary(status: .available, topology: topo, force: true)
                    case .notRunning: self.publishSummary(status: .notRunning, topology: nil, force: true)
                    case .configMissing: self.publishSummary(status: .configMissing, topology: nil, force: true)
                    case .nonLocalController: self.publishSummary(status: .nonLocalController, topology: nil, force: true)
                    case .authFailed: self.publishSummary(status: .authFailed, topology: nil, force: true)
                    case .decodeFailed: self.publishSummary(status: .decodeFailed, topology: nil, force: true)
                    case .cancelled: break
                    }
                }
            }
        }
    }

    // MARK: 低资源定时器与内核目录监听

    private func scheduleTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .seconds(Self.baseTimerIntervalSeconds),
                   repeating: .seconds(Self.baseTimerIntervalSeconds),
                   leeway: .seconds(5))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
    }

    /// 当前来源的配置目录（随来源/自定义路径变化）。
    private var currentConfigDirectoryPath: String? {
        BettboxClient.configDirectory(source: config.source, customPath: config.customConfigPath)?.path
    }

    /// 使用内核 kqueue vnode 监听当前来源的配置目录，切换配置秒级感知，空闲期 0 CPU。
    private func startDirectoryWatcher() {
        guard dirMonitor == nil else { return }
        guard let path = currentConfigDirectoryPath else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        watchedDirectoryPath = path
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: queue)
        source.setEventHandler { [weak self] in
            self?.scheduleConfigChangeCheck()
        }
        source.setCancelHandler { [fd] in
            close(fd)
        }
        dirMonitor = source
        source.resume()
    }

    private func stopDirectoryWatcher() {
        configChangeDebounce?.cancel()
        configChangeDebounce = nil
        if let m = dirMonitor {
            m.cancel()
            dirMonitor = nil
        }
        watchedDirectoryPath = nil
    }

    private func scheduleConfigChangeCheck() {
        configChangeDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.handlePotentialConfigChange()
        }
        configChangeDebounce = work
        queue.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func handlePotentialConfigChange() {
        guard enabled, !paused else { return }
        if refreshConfigCacheIfNeeded() {
            let now = Date()
            generation += 1
            pendingManualWatch = false
            pendingManualBulk = false
            pendingAdHocGroup = nil
            cancelWatchTask()
            cancelActiveTask()
            // Bettbox 刚重载配置后 30 秒内跳过被动吸收，避开数百并发重载风暴带来的假离线。
            reloadSuppressUntil = now.addingTimeInterval(Self.reloadStormSuppressSeconds)
            lastPassiveAt = .distantPast
            lastWatchAt = .distantPast
            lastActiveAt = .distantPast
            nextActiveAllowedAt = now.addingTimeInterval(8)
            if panelVisible { performPanelSummaryRefresh() }
        }
    }

    private func ensureStore() -> HistoryStore? {
        if store == nil { store = HistoryStore(migrate: true, calendar: calendar) }
        if let store, !storePreloaded {
            storePreloaded = true
            lastSeenMs = store.nodeLatestProbeTimestamps()
        }
        return store
    }

    private func cancelWatchTask() {
        let wasRunning = watchInFlight
        watchRunID += 1
        watchTask?.cancel()
        watchTask = nil
        watchInFlight = false
        if wasRunning { markLiveProgressCancelledIfNeeded() }
    }

    private func cancelActiveTask() {
        let wasRunning = activeInFlight
        activeRunID += 1
        activeTask?.cancel()
        activeTask = nil
        activeInFlight = false
        if wasRunning { markLiveProgressCancelledIfNeeded() }
    }

    @discardableResult
    private func refreshConfigCacheIfNeeded() -> Bool {
        let source = config.source
        let customPath = config.customConfigPath
        let fp = BettboxClient.configFingerprint(forSource: source, customPath: customPath)
        if fp == lastConfigFingerprint && cachedClient != nil {
            return false
        }
        let hadPrevious = !lastConfigFingerprint.isEmpty
        lastConfigFingerprint = fp
        switch BettboxClient.resolve(source: source, customPath: customPath) {
        case .success(let resolved):
            cachedProfile = BettboxClient.profile(for: resolved)
            cachedClient = BettboxClient.make(config: resolved.text,
                                              source: resolved.source,
                                              sourceId: resolved.sourceId,
                                              configURL: resolved.configURL)
        case .failure:
            cachedProfile = source == .bettbox
                ? .fallback
                : BettboxProfileInfo(id: "\(source.sourceId):default", label: "")
            cachedClient = BettboxClient.load(source: source, customPath: customPath)
        }
        // 配置目录可能随来源变化：指纹变化后按需重建目录监听。
        if !lastConfigFingerprint.isEmpty, dirMonitor != nil,
           watchedDirectoryPath != currentConfigDirectoryPath {
            stopDirectoryWatcher()
            if enabled { startDirectoryWatcher() }
        }
        return hadPrevious
    }

    /// 严格互斥调度：任一时刻只跑一条轨道（分组盯梢 → 批量主动 → 被动清洗），
    /// 彻底杜绝跨轨并发超上限、同叶重复发包与主被动双写，且每轨完成后立即接续排队的其他轨道。
    private func tick() {
        guard enabled, !paused else { return }
        if dirMonitor == nil || watchedDirectoryPath != currentConfigDirectoryPath {
            stopDirectoryWatcher()
            startDirectoryWatcher()
        }
        let now = Date()
        if refreshConfigCacheIfNeeded() {
            generation += 1
            pendingManualWatch = false
            pendingManualBulk = false
            pendingAdHocGroup = nil
            cancelWatchTask()
            cancelActiveTask()
            reloadSuppressUntil = now.addingTimeInterval(Self.reloadStormSuppressSeconds)
            lastPassiveAt = .distantPast
            lastWatchAt = .distantPast
            lastActiveAt = .distantPast
            nextActiveAllowedAt = now.addingTimeInterval(8)
        }

        guard !passiveInFlight, !watchInFlight, !activeInFlight else { return }

        // 0. 用户针对当前浏览策略组触发的一次性即时测速。
        if let adHoc = pendingAdHocGroup {
            pendingAdHocGroup = nil
            startActiveProbe(force: true, overrideScope: NodeProbeScope(groups: [adHoc]), startedAt: now)
            return
        }

        let curScope = config.scopes[cachedProfile.id] ?? NodeProbeScope()

        // 1. 选定分组当前出口通道监测（5 分钟周期，极轻 1–5 个请求，最高优先级）。
        let watchDue = pendingManualWatch
            || (curScope.hasWatchedGroups && now >= nextActiveAllowedAt
                && now.timeIntervalSince(lastWatchAt)
                    >= TimeInterval(config.watchIntervalMinutes * 60 - 5))
        if watchDue && curScope.hasWatchedGroups {
            pendingManualWatch = false
            startWatchedGroupProbe(startedAt: now)
            return
        }
        pendingManualWatch = false

        // 2. 轨道 B（候选组低频批量主动探测，默认关闭；手动立即探测亦在此接续）。
        let manualBulk = pendingManualBulk
        let scheduledBulk = config.activeEnabled && !curScope.isEmpty && now >= nextActiveAllowedAt
            && now.timeIntervalSince(lastActiveAt) >= TimeInterval(config.intervalMinutes * 60 - 5)
        if (manualBulk || scheduledBulk) && !curScope.isEmpty {
            pendingManualBulk = false
            startActiveProbe(force: manualBulk, overrideScope: nil, startedAt: now)
            return
        }
        pendingManualBulk = false

        // 3. 轨道 A（被动清洗）：仅在未处配置重载 30s 风暴期且到 60s 周期时执行。
        if now >= reloadSuppressUntil,
           now.timeIntervalSince(lastPassiveAt) >= TimeInterval(Self.baseTimerIntervalSeconds - 5) {
            startPassiveSync(startedAt: now)
        }
    }

    // MARK: 轨道 A — 被动吸收（已校准清洗）

    private func startPassiveSync(startedAt: Date) {
        guard !passiveInFlight, !activeInFlight, !watchInFlight else { return }
        guard case .success(let client) = cachedClient ?? BettboxClient.load(source: config.source, customPath: config.customConfigPath) else { return }
        guard ensureStore() != nil else { return }
        passiveInFlight = true
        lastPassiveAt = startedAt
        let gen = generation
        let probeURL = config.probeURL

        Task { [weak self] in
            let result = await client.fetchProxies()
            guard let self else { return }
            self.queue.async {
                self.passiveInFlight = false
                guard self.enabled, !self.paused, !self.activeInFlight, !self.watchInFlight, gen == self.generation else {
                    self.tick()
                    return
                }
                guard case .available(let payload) = result else {
                    if self.panelVisible {
                        switch result {
                        case .notRunning: self.publishSummary(status: .notRunning, topology: nil, force: false)
                        case .authFailed: self.publishSummary(status: .authFailed, topology: nil, force: false)
                        case .decodeFailed: self.publishSummary(status: .decodeFailed, topology: nil, force: false)
                        default: break
                        }
                    }
                    self.tick()
                    return
                }
                let now = Date()
                let topology = NodeTopology(payload: payload, groupOrder: client.groupOrder)
                self.lastTopology = topology
                // 在 queue 回调内实时读取最新 lastSeenMs 与 clearedAtMs，避免与中途完成的主动探测撞窗双写。
                let extracted = PassiveHistoryExtractor.extractWithWatermarks(
                    from: topology, now: now, lastSeenMs: self.lastSeenMs,
                    clearedAtMs: self.clearedAtMs, preferredURL: probeURL
                )
                // 先推进风暴门控丢弃的水位，防止次轮同桶节点跌破阈值后假离线漏写进库。
                for (key, tsMs) in extracted.droppedWatermarks {
                    let cur = self.lastSeenMs[key] ?? Int64.min
                    if tsMs > cur { self.lastSeenMs[key] = tsMs }
                }
                if !extracted.samples.isEmpty, let store = self.ensureStore(),
                   store.addNodeProbes(extracted.samples, calendar: self.calendar) {
                    for s in extracted.samples {
                        let cur = self.lastSeenMs[s.key] ?? Int64.min
                        if s.tsMs > cur { self.lastSeenMs[s.key] = s.tsMs }
                    }
                }
                if self.panelVisible {
                    self.publishSummary(status: .available, topology: topology, force: false)
                }
                self.tick()
            }
        }
    }

    // MARK: 分组服务通道 5 分钟监测（1A + 2B 断线通知）

    private func startWatchedGroupProbe(startedAt: Date) {
        guard !watchInFlight, !activeInFlight, !passiveInFlight else { return }
        guard case .success(let client) = cachedClient ?? BettboxClient.load(source: config.source, customPath: config.customConfigPath) else { return }
        guard ensureStore() != nil else { return }

        let profile = cachedProfile
        let watched = config.scopes[profile.id]?.watchedGroups ?? []
        guard !watched.isEmpty else { return }

        watchRunID += 1
        let runID = watchRunID
        progressRunSeq += 1
        let progRunId = progressRunSeq
        watchInFlight = true
        lastWatchAt = startedAt
        let gen = generation
        let probeURL = config.probeURL
        let timeoutMs = config.timeoutMs
        let expectedFingerprint = lastConfigFingerprint
        let fingerprintSource = config.source
        let fingerprintPath = config.customConfigPath

        emitProgress(NodeProbeLiveProgress(
            runId: progRunId, phase: .checkingDirect, total: watched.count,
            completed: 0, online: 0, offline: 0, activeNodes: [], recentResults: [],
            flushedSamples: 0, updatedAt: Date().timeIntervalSince1970
        ))

        watchTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await Self.executeWatchedGroupRound(
                client: client,
                profileId: profile.id,
                watchedGroups: watched,
                probeURL: probeURL,
                timeoutMs: timeoutMs,
                progressRunId: progRunId,
                onProgress: { [weak self] progress in
                    self?.queue.async {
                        guard let self, runID == self.watchRunID, self.enabled, !self.paused, gen == self.generation else { return }
                        self.emitProgress(progress)
                    }
                },
                isStillValid: {
                    !Task.isCancelled && BettboxClient.configFingerprint(
                        forSource: fingerprintSource, customPath: fingerprintPath) == expectedFingerprint
                }
            )
            self.queue.async {
                guard runID == self.watchRunID else { return }
                self.watchInFlight = false
                self.watchTask = nil
                guard self.enabled, !self.paused, gen == self.generation else { return }

                if let topo = outcome.topology { self.lastTopology = topo }
                var flushed = 0
                if let store = self.ensureStore() {
                    if !outcome.nodeSamples.isEmpty, store.addNodeProbes(outcome.nodeSamples, calendar: self.calendar) {
                        flushed += outcome.nodeSamples.count
                        for s in outcome.nodeSamples {
                            let protectedTs = s.tsMs + Self.activeDedupBufferMs
                            let cur = self.lastSeenMs[s.key] ?? Int64.min
                            if protectedTs > cur { self.lastSeenMs[s.key] = protectedTs }
                        }
                    }
                    if !outcome.groupSamples.isEmpty,
                       let failCounts = store.addGroupWatchSamples(
                           outcome.groupSamples,
                           calendar: self.calendar,
                           continuityWindowMs: self.groupContinuityWindowMs
                       ) {
                        flushed += outcome.groupSamples.count
                        if self.config.groupAlertEnabled {
                            for s in outcome.groupSamples where !s.ok {
                                if failCounts[s.groupName] == Self.groupOfflineNotifyThreshold {
                                    Self.notifyGroupOffline(groupName: s.groupName, nodeName: s.currentNode)
                                }
                            }
                        }
                    }
                }
                if var finalProg = outcome.finalProgress {
                    finalProg.flushedSamples = flushed
                    finalProg.updatedAt = Date().timeIntervalSince1970
                    self.emitProgress(finalProg)
                }
                if self.panelVisible {
                    self.publishSummary(status: self.lastTopology != nil ? .available : .starting, topology: self.lastTopology, force: false)
                }
                // 完成后立即接续可能排队的手动批量主动探测或被动同步。
                self.tick()
            }
        }
    }

    /// 连续失败判定窗口：随用户探测间隔放大，避免 10/15/30 分钟周期被 20 分钟硬编码窗口清零。
    private var groupContinuityWindowMs: Int64 {
        max(HistoryStore.groupFailureContinuityWindowMs,
            Int64(max(config.watchIntervalMinutes, 1)) * 4 * 60 * 1000)
    }

    private struct WatchedGroupRoundOutcome {
        var topology: NodeTopology?
        var groupSamples: [GroupWatchSample] = []
        var nodeSamples: [NodeProbeSample] = []
        var finalProgress: NodeProbeLiveProgress?
    }

    private static func executeWatchedGroupRound(
        client: BettboxClient,
        profileId: String,
        watchedGroups: [String],
        probeURL: String,
        timeoutMs: Int,
        progressRunId: Int,
        onProgress: @escaping @Sendable (NodeProbeLiveProgress) -> Void,
        isStillValid: @escaping @Sendable () -> Bool
    ) async -> WatchedGroupRoundOutcome {
        guard isStillValid() else {
            return WatchedGroupRoundOutcome(finalProgress: NodeProbeLiveProgress(
                runId: progressRunId, phase: .cancelled, total: watchedGroups.count,
                completed: 0, online: 0, offline: 0, activeNodes: [], recentResults: [],
                flushedSamples: 0, updatedAt: Date().timeIntervalSince1970
            ))
        }
        // 1. DIRECT 本机联网门控
        switch await checkDirectOnline(client: client, probeURL: probeURL, timeoutMs: timeoutMs,
                                       retryOnTimeout: true, isStillValid: isStillValid) {
        case .ok: break
        case .timeout:
            return WatchedGroupRoundOutcome(finalProgress: NodeProbeLiveProgress(
                runId: progressRunId, phase: .skippedOffline, total: watchedGroups.count,
                completed: 0, online: 0, offline: 0, activeNodes: [], recentResults: [],
                flushedSamples: 0, updatedAt: Date().timeIntervalSince1970
            ))
        default:
            return WatchedGroupRoundOutcome(finalProgress: NodeProbeLiveProgress(
                runId: progressRunId, phase: .cancelled, total: watchedGroups.count,
                completed: 0, online: 0, offline: 0, activeNodes: [], recentResults: [],
                flushedSamples: 0, updatedAt: Date().timeIntervalSince1970
            ))
        }
        // 2. 拉最新拓扑并穿透解析当前实际出站叶节点
        guard isStillValid(), case .available(let payload) = await client.fetchProxies() else {
            return WatchedGroupRoundOutcome(finalProgress: NodeProbeLiveProgress(
                runId: progressRunId, phase: .cancelled, total: watchedGroups.count,
                completed: 0, online: 0, offline: 0, activeNodes: [], recentResults: [],
                flushedSamples: 0, updatedAt: Date().timeIntervalSince1970
            ))
        }
        let topology = NodeTopology(payload: payload, groupOrder: client.groupOrder)
        let plan = ActiveProbePlanner.planWatchedGroups(topology: topology, watchedGroups: watchedGroups)
        guard !plan.isEmpty else {
            return WatchedGroupRoundOutcome(topology: topology, finalProgress: NodeProbeLiveProgress(
                runId: progressRunId, phase: .finished, total: 0,
                completed: 0, online: 0, offline: 0, activeNodes: [], recentResults: [],
                flushedSamples: 0, updatedAt: Date().timeIntervalSince1970
            ))
        }

        // 3. 按叶节点去重只测 1 次（多分组指向同一节点零冗余发包）
        var uniqueLeaves: [(key: NodeKey, leaf: ProxyEntry, groupHint: String)] = []
        var seenLeaf = Set<NodeKey>()
        for item in plan where seenLeaf.insert(item.leaf.key).inserted {
            uniqueLeaves.append((item.leaf.key, item.leaf, item.groupName))
        }

        var leafResults: [NodeKey: (result: NodeDelayResult, tsMs: Int64)] = [:]
        var abortedByController = false
        var completed = 0
        var online = 0
        var offline = 0
        var recent: [NodeProbeLiveEvent] = []

        for item in uniqueLeaves {
            guard isStillValid() else {
                return WatchedGroupRoundOutcome(topology: topology, finalProgress: NodeProbeLiveProgress(
                    runId: progressRunId, phase: .cancelled, total: uniqueLeaves.count,
                    completed: completed, online: online, offline: offline, activeNodes: [],
                    recentResults: recent, flushedSamples: 0, updatedAt: Date().timeIntervalSince1970
                ))
            }
            onProgress(NodeProbeLiveProgress(
                runId: progressRunId, phase: .watchingGroups, total: uniqueLeaves.count,
                completed: completed, online: online, offline: offline, activeNodes: [item.leaf.name],
                recentResults: recent, flushedSamples: 0, updatedAt: Date().timeIntervalSince1970
            ))
            let res = await client.testDelay(proxyName: item.leaf.name, probeURL: probeURL, timeoutMs: timeoutMs)
            let tsMs = Int64((Date().timeIntervalSince1970 * 1000.0).rounded())
            if res == .controllerUnavailable || res == .authFailed || res == .cancelled {
                abortedByController = true
                break
            }
            leafResults[item.key] = (res, tsMs)
            completed += 1
            switch res {
            case .ok(let ms):
                online += 1
                recent.insert(NodeProbeLiveEvent(id: "\(tsMs)-\(item.leaf.name)", node: item.leaf.name,
                                                 groupName: item.groupHint, ok: true, delayMs: ms, tsMs: tsMs), at: 0)
            case .timeout:
                offline += 1
                recent.insert(NodeProbeLiveEvent(id: "\(tsMs)-\(item.leaf.name)", node: item.leaf.name,
                                                 groupName: item.groupHint, ok: false, delayMs: 0, tsMs: tsMs), at: 0)
            default: break
            }
            if recent.count > 6 { recent = Array(recent.prefix(6)) }
        }
        guard isStillValid(), !abortedByController else {
            return WatchedGroupRoundOutcome(topology: topology, finalProgress: NodeProbeLiveProgress(
                runId: progressRunId, phase: .cancelled, total: uniqueLeaves.count,
                completed: completed, online: online, offline: offline, activeNodes: [],
                recentResults: recent, flushedSamples: 0, updatedAt: Date().timeIntervalSince1970
            ))
        }

        // 4. 若本轮存在超时节点，复测一次 DIRECT 确认本机未断网，防止误发断线通知。
        if leafResults.values.contains(where: { $0.result == .timeout }) {
            guard case .ok = await checkDirectOnline(client: client, probeURL: probeURL, timeoutMs: timeoutMs,
                                                     retryOnTimeout: false, isStillValid: isStillValid) else {
                return WatchedGroupRoundOutcome(topology: topology, finalProgress: NodeProbeLiveProgress(
                    runId: progressRunId, phase: .skippedOffline, total: uniqueLeaves.count,
                    completed: completed, online: online, offline: offline, activeNodes: [],
                    recentResults: recent, flushedSamples: 0, updatedAt: Date().timeIntervalSince1970
                ))
            }
        }

        var groupSamples: [GroupWatchSample] = []
        var nodeSamples: [NodeProbeSample] = []

        for item in uniqueLeaves {
            guard let entry = leafResults[item.key] else { continue }
            switch entry.result {
            case .ok(let ms):
                nodeSamples.append(NodeProbeSample(tsMs: entry.tsMs, node: item.leaf.name, dialer: item.leaf.dialerProxy,
                                                   nodeType: item.leaf.type, delayMs: ms, ok: true, source: .active))
            case .timeout:
                nodeSamples.append(NodeProbeSample(tsMs: entry.tsMs, node: item.leaf.name, dialer: item.leaf.dialerProxy,
                                                   nodeType: item.leaf.type, delayMs: 0, ok: false, source: .active))
            default: break
            }
        }

        for item in plan {
            guard let entry = leafResults[item.leaf.key] else { continue }
            switch entry.result {
            case .ok(let ms):
                groupSamples.append(GroupWatchSample(tsMs: entry.tsMs, profileId: profileId, groupName: item.groupName,
                                                     currentNode: item.leaf.name, dialer: item.leaf.dialerProxy,
                                                     delayMs: ms, ok: true))
            case .timeout:
                groupSamples.append(GroupWatchSample(tsMs: entry.tsMs, profileId: profileId, groupName: item.groupName,
                                                     currentNode: item.leaf.name, dialer: item.leaf.dialerProxy,
                                                     delayMs: 0, ok: false))
            default: break
            }
        }

        return WatchedGroupRoundOutcome(
            topology: topology,
            groupSamples: groupSamples,
            nodeSamples: nodeSamples,
            finalProgress: NodeProbeLiveProgress(
                runId: progressRunId, phase: .finished, total: uniqueLeaves.count,
                completed: completed, online: online, offline: offline, activeNodes: [],
                recentResults: recent, flushedSamples: 0, updatedAt: Date().timeIntervalSince1970
            )
        )
    }

    private static func notifyGroupOffline(groupName: String, nodeName: String) {
        let content = UNMutableNotificationContent()
        content.title = "Zest Plus · \(L10n.text("nodes.alert.title", defaultValue: "分组出口断线"))"
        content.body = String(format: L10n.text("nodes.alert.body"), groupName, nodeName)
        let center = UNUserNotificationCenter.current()
        let send = { center.add(UNNotificationRequest(identifier: "group-offline-\(groupName)", content: content, trigger: nil)) }
        center.getNotificationSettings { s in
            switch s.authorizationStatus {
            case .denied: break
            case .notDetermined: center.requestAuthorization(options: [.alert, .sound]) { ok, _ in if ok { send() } }
            default: send()
            }
        }
    }

    // MARK: 轨道 B — 候选组低频批量主动探测（自动联动链式前置 + 边测边写 + 实时进度广播）

    private func startActiveProbe(force: Bool, overrideScope: NodeProbeScope?, startedAt: Date) {
        guard !activeInFlight, !watchInFlight, !passiveInFlight else { return }
        guard force || config.activeEnabled else { return }
        guard case .success(let client) = cachedClient ?? BettboxClient.load(source: config.source, customPath: config.customConfigPath) else { return }
        guard ensureStore() != nil else { return }

        let profile = cachedProfile
        let scope = overrideScope ?? (config.scopes[profile.id] ?? NodeProbeScope())
        guard !scope.isEmpty else { return }

        activeRunID += 1
        let runID = activeRunID
        progressRunSeq += 1
        let progRunId = progressRunSeq
        activeInFlight = true
        if overrideScope == nil { lastActiveAt = startedAt }
        let gen = generation
        let probeURL = config.probeURL
        let timeoutMs = config.timeoutMs
        let expectedFingerprint = lastConfigFingerprint
        let fingerprintSource = config.source
        let fingerprintPath = config.customConfigPath

        emitProgress(NodeProbeLiveProgress(
            runId: progRunId, phase: .checkingDirect, total: 0,
            completed: 0, online: 0, offline: 0, activeNodes: [], recentResults: [],
            flushedSamples: 0, updatedAt: Date().timeIntervalSince1970
        ))

        activeTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await Self.executeActiveRound(
                client: client,
                profileId: profile.id,
                scope: scope,
                probeURL: probeURL,
                timeoutMs: timeoutMs,
                progressRunId: progRunId,
                onFlushSamples: { [weak self] batch in
                    guard let self, !batch.isEmpty else { return 0 }
                    return await withCheckedContinuation { cont in
                        self.queue.async {
                            guard runID == self.activeRunID, self.enabled, !self.paused, gen == self.generation,
                                  let store = self.ensureStore(),
                                  store.addNodeProbes(batch, calendar: self.calendar) else {
                                cont.resume(returning: 0)
                                return
                            }
                            for s in batch {
                                let protectedTs = s.tsMs + Self.activeDedupBufferMs
                                let cur = self.lastSeenMs[s.key] ?? Int64.min
                                if protectedTs > cur { self.lastSeenMs[s.key] = protectedTs }
                            }
                            if self.panelVisible {
                                self.publishSummary(status: self.lastTopology != nil ? .available : .starting, topology: self.lastTopology, force: false)
                            }
                            cont.resume(returning: batch.count)
                        }
                    }
                },
                onProgress: { [weak self] progress in
                    self?.queue.async {
                        guard let self, runID == self.activeRunID, self.enabled, !self.paused, gen == self.generation else { return }
                        self.emitProgress(progress)
                    }
                },
                isStillValid: {
                    !Task.isCancelled && BettboxClient.configFingerprint(
                        forSource: fingerprintSource, customPath: fingerprintPath) == expectedFingerprint
                }
            )
            self.queue.async {
                guard runID == self.activeRunID else { return }
                self.activeInFlight = false
                self.activeTask = nil
                guard self.enabled, !self.paused, gen == self.generation else { return }

                var extraFlushed = 0
                var persisted = true
                if !outcome.remainingSamples.isEmpty {
                    if let store = self.ensureStore(), store.addNodeProbes(outcome.remainingSamples, calendar: self.calendar) {
                        extraFlushed = outcome.remainingSamples.count
                        for s in outcome.remainingSamples {
                            let protectedTs = s.tsMs + Self.activeDedupBufferMs
                            let cur = self.lastSeenMs[s.key] ?? Int64.min
                            if protectedTs > cur { self.lastSeenMs[s.key] = protectedTs }
                        }
                    } else {
                        persisted = false
                    }
                }
                if persisted, let info = outcome.runInfo, let encoded = try? JSONEncoder().encode(info) {
                    UserDefaults.standard.set(encoded, forKey: Self.lastActiveRunDefaultsKey)
                }
                if var finalProg = outcome.finalProgress {
                    finalProg.flushedSamples += extraFlushed
                    finalProg.updatedAt = Date().timeIntervalSince1970
                    self.emitProgress(finalProg)
                }
                if self.panelVisible {
                    self.publishSummary(status: self.lastTopology != nil ? .available : .starting, topology: self.lastTopology, force: false)
                }
                self.tick()
            }
        }
    }

    // MARK: 面板摘要（严格三态 + 等权聚合 + 选定分组状态）

    private func publishSummary(status: NodeMonitorStatus, topology: NodeTopology?, force: Bool) {
        guard let onSummary, (force || panelVisible) else { return }
        let now = Date()
        let nowMs = Int64((now.timeIntervalSince1970 * 1000.0).rounded())
        let store = ensureStore()
        let summaries = store?.nodeSummaries(sourceFilter: .all, now: now, calendar: calendar) ?? [:]
        let profile = cachedProfile
        let profileName = profile.label.isEmpty ? profile.id : profile.label
        let scope = config.scopes[profile.id] ?? NodeProbeScope()
        let groupMap = store?.groupWatchSummaries(profileId: profile.id, now: now, calendar: calendar) ?? [:]

        var d1List: [NodeWindowMetrics] = []
        var d7List: [NodeWindowMetrics] = []
        var d30List: [NodeWindowMetrics] = []
        var total = 0
        var online = 0
        var offline = 0
        var untested = 0
        var chains = 0

        if let topology {
            total = topology.leaves.count
            for (key, entry) in topology.leaves {
                if entry.isChain { chains += 1 }
                let rec = summaries[key]
                if let rec {
                    d1List.append(rec.day1)
                    d7List.append(rec.day7)
                    d30List.append(rec.day30)
                }
                // 严格三态：DB 无记录时走统一兜底（受 maxAgeMs 与 clearedAtMs 约束），绝不采信 Mihomo 默认 alive=true。
                if let latest = rec?.latest {
                    if latest.ok { online += 1 } else { offline += 1 }
                } else if let fb = PassiveHistoryExtractor.latestValidFallback(
                    for: entry, nowMs: nowMs, clearedAtMs: clearedAtMs, preferredURL: config.probeURL
                ) {
                    if fb.ok { online += 1 } else { offline += 1 }
                } else {
                    untested += 1
                }
            }
        } else {
            for rec in summaries.values {
                d1List.append(rec.day1)
                d7List.append(rec.day7)
                d30List.append(rec.day30)
            }
        }

        // 组装当前配置选定盯住分组摘要（即使尚无样本也列出当前实际出站节点）
        var watchedList: [GroupWatchSummaryRecord] = []
        for gName in scope.watchedGroups {
            let liveLeaf = topology?.resolveCurrentLeaf(ofGroup: gName)
            if var rec = groupMap[gName] {
                if let liveLeaf {
                    rec.currentNode = liveLeaf.name
                    rec.dialer = liveLeaf.dialerProxy
                }
                watchedList.append(rec)
            } else if let liveLeaf {
                watchedList.append(GroupWatchSummaryRecord(groupName: gName, currentNode: liveLeaf.name, dialer: liveLeaf.dialerProxy))
            }
        }

        var lastRun: NodeActiveProbeRunInfo?
        if let data = UserDefaults.standard.data(forKey: Self.lastActiveRunDefaultsKey),
           let info = try? JSONDecoder().decode(NodeActiveProbeRunInfo.self, from: data),
           info.profileId == profile.id {
            lastRun = info
        }

        onSummary(NodePanelSummary(
            status: status,
            profileName: profileName,
            totalNodes: total,
            onlineNodes: online,
            offlineNodes: offline,
            untestedNodes: untested,
            chainNodes: chains,
            day1: NodeEqualWeightAggregate.compute(from: d1List),
            day7: NodeEqualWeightAggregate.compute(from: d7List),
            day30: NodeEqualWeightAggregate.compute(from: d30List),
            watchedGroups: watchedList,
            activeEnabled: config.activeEnabled,
            activeGroups: scope.groups.count,
            lastActiveRun: lastRun
        ))
    }

    // MARK: 公共辅助

    private struct ActiveRoundOutcome {
        var remainingSamples: [NodeProbeSample] = []
        var runInfo: NodeActiveProbeRunInfo?
        var finalProgress: NodeProbeLiveProgress?
    }

    private static func checkDirectOnline(client: BettboxClient, probeURL: String, timeoutMs: Int,
                                          retryOnTimeout: Bool,
                                          isStillValid: @escaping @Sendable () -> Bool) async -> NodeDelayResult {
        let directTimeout = min(timeoutMs, 3000)
        var res = await client.testDelay(proxyName: "DIRECT", probeURL: probeURL, timeoutMs: directTimeout)
        if retryOnTimeout, res == .timeout, isStillValid() {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            res = await client.testDelay(proxyName: "DIRECT", probeURL: probeURL, timeoutMs: directTimeout)
        }
        return res
    }

    private static func executeActiveRound(
        client: BettboxClient,
        profileId: String,
        scope: NodeProbeScope,
        probeURL: String,
        timeoutMs: Int,
        progressRunId: Int,
        onFlushSamples: @escaping @Sendable ([NodeProbeSample]) async -> Int,
        onProgress: @escaping @Sendable (NodeProbeLiveProgress) -> Void,
        isStillValid: @escaping @Sendable () -> Bool
    ) async -> ActiveRoundOutcome {
        guard isStillValid() else {
            return ActiveRoundOutcome(finalProgress: NodeProbeLiveProgress(
                runId: progressRunId, phase: .cancelled, total: 0, completed: 0,
                online: 0, offline: 0, activeNodes: [], recentResults: [],
                flushedSamples: 0, updatedAt: Date().timeIntervalSince1970
            ))
        }

        switch await checkDirectOnline(client: client, probeURL: probeURL, timeoutMs: timeoutMs,
                                       retryOnTimeout: true, isStillValid: isStillValid) {
        case .ok: break
        case .timeout:
            return ActiveRoundOutcome(
                runInfo: NodeActiveProbeRunInfo(finishedAt: Date().timeIntervalSince1970, profileId: profileId,
                                                probed: 0, online: 0, skippedReason: "offline"),
                finalProgress: NodeProbeLiveProgress(
                    runId: progressRunId, phase: .skippedOffline, total: 0, completed: 0,
                    online: 0, offline: 0, activeNodes: [], recentResults: [],
                    flushedSamples: 0, updatedAt: Date().timeIntervalSince1970
                )
            )
        case .authFailed, .controllerUnavailable, .cancelled, .notFound:
            return ActiveRoundOutcome(finalProgress: NodeProbeLiveProgress(
                runId: progressRunId, phase: .cancelled, total: 0, completed: 0,
                online: 0, offline: 0, activeNodes: [], recentResults: [],
                flushedSamples: 0, updatedAt: Date().timeIntervalSince1970
            ))
        }

        guard isStillValid() else {
            return ActiveRoundOutcome(finalProgress: NodeProbeLiveProgress(
                runId: progressRunId, phase: .cancelled, total: 0, completed: 0,
                online: 0, offline: 0, activeNodes: [], recentResults: [],
                flushedSamples: 0, updatedAt: Date().timeIntervalSince1970
            ))
        }
        guard case .available(let payload) = await client.fetchProxies() else {
            return ActiveRoundOutcome(finalProgress: NodeProbeLiveProgress(
                runId: progressRunId, phase: .cancelled, total: 0, completed: 0,
                online: 0, offline: 0, activeNodes: [], recentResults: [],
                flushedSamples: 0, updatedAt: Date().timeIntervalSince1970
            ))
        }
        let topology = NodeTopology(payload: payload, groupOrder: client.groupOrder)
        // 默认自动联动纳入链式节点的前置 dialer-proxy 叶节点（含 ⛓ 中转节点）。
        let targets = ActiveProbePlanner.plan(topology: topology, scope: scope, includeChainUpstreams: true)
        guard !targets.isEmpty else {
            return ActiveRoundOutcome(finalProgress: NodeProbeLiveProgress(
                runId: progressRunId, phase: .finished, total: 0, completed: 0,
                online: 0, offline: 0, activeNodes: [], recentResults: [],
                flushedSamples: 0, updatedAt: Date().timeIntervalSince1970
            ))
        }

        let totalTargets = targets.count
        var pending = targets
        var inFlightBuckets = Set<String>()
        var inFlightNodes: [String] = []
        var inFlightCount = 0
        var pendingOkBuffer: [NodeProbeSample] = []
        var pendingTimeoutBuffer: [NodeProbeSample] = []
        var pendingTimeoutEventIds = Set<String>()
        var totalCompleted = 0
        var totalOnline = 0
        var totalOffline = 0
        var totalFlushed = 0
        var recentResults: [NodeProbeLiveEvent] = []
        var consecutiveTimeouts = 0
        var abortedByController = false
        var abortedByLocalOffline = false
        var lastOkFlushAt = Date()
        var lastTimeoutFlushAt = Date()
        var lastProgressEmitAt = Date.distantPast

        func discardPendingTimeouts() {
            guard !pendingTimeoutBuffer.isEmpty else { return }
            let dropped = pendingTimeoutBuffer.count
            totalOffline = max(0, totalOffline - dropped)
            totalCompleted = max(0, totalCompleted - dropped)
            if !pendingTimeoutEventIds.isEmpty {
                recentResults.removeAll { pendingTimeoutEventIds.contains($0.id) }
                pendingTimeoutEventIds.removeAll()
            }
            pendingTimeoutBuffer.removeAll()
        }

        func pushProgress(force: Bool) {
            let now = Date()
            if !force && now.timeIntervalSince(lastProgressEmitAt) < 0.22 { return }
            lastProgressEmitAt = now
            onProgress(NodeProbeLiveProgress(
                runId: progressRunId, phase: .probingBulk, total: totalTargets,
                completed: totalCompleted, online: totalOnline, offline: totalOffline,
                activeNodes: inFlightNodes, recentResults: recentResults,
                flushedSamples: totalFlushed, updatedAt: now.timeIntervalSince1970
            ))
        }

        await withTaskGroup(of: (ActiveProbeTarget, NodeDelayResult, Int64).self) { group in
            func scheduleAvailable() {
                while inFlightCount < maxConcurrency, !abortedByController, !abortedByLocalOffline, isStillValid() {
                    guard let idx = pending.firstIndex(where: { t in
                        guard let b = t.landingBucket else { return true }
                        return !inFlightBuckets.contains(b)
                    }) else { break }
                    let target = pending.remove(at: idx)
                    if let b = target.landingBucket { inFlightBuckets.insert(b) }
                    inFlightNodes.append(target.key.name)
                    inFlightCount += 1
                    group.addTask {
                        let res = await client.testDelay(proxyName: target.key.name, probeURL: probeURL, timeoutMs: timeoutMs)
                        let tsMs = Int64((Date().timeIntervalSince1970 * 1000.0).rounded())
                        return (target, res, tsMs)
                    }
                }
            }

            scheduleAvailable()
            pushProgress(force: true)

            while let (target, result, tsMs) = await group.next() {
                inFlightCount -= 1
                if let b = target.landingBucket { inFlightBuckets.remove(b) }
                if let idx = inFlightNodes.firstIndex(of: target.key.name) {
                    inFlightNodes.remove(at: idx)
                }
                if !isStillValid() {
                    group.cancelAll()
                    break
                }
                if abortedByController || abortedByLocalOffline {
                    // 中止排空阶段仅保留已经明确在线返回的样本，不再处理超时或被取消任务，避免重复 DIRECT 复检与计数虚增。
                    if case .ok(let ms) = result {
                        totalCompleted += 1
                        totalOnline += 1
                        pendingOkBuffer.append(NodeProbeSample(tsMs: tsMs, node: target.key.name, dialer: target.key.dialer,
                                                               nodeType: target.nodeType, delayMs: ms, ok: true, source: .active))
                    }
                    continue
                }
                var flushedNow = false
                switch result {
                case .ok(let ms):
                    consecutiveTimeouts = 0
                    totalCompleted += 1
                    totalOnline += 1
                    pendingOkBuffer.append(NodeProbeSample(tsMs: tsMs, node: target.key.name, dialer: target.key.dialer,
                                                           nodeType: target.nodeType, delayMs: ms, ok: true, source: .active))
                    recentResults.insert(NodeProbeLiveEvent(id: "\(tsMs)-\(target.key.name)", node: target.key.name,
                                                            groupName: nil, ok: true, delayMs: ms, tsMs: tsMs), at: 0)
                case .timeout:
                    consecutiveTimeouts += 1
                    totalCompleted += 1
                    totalOffline += 1
                    let evId = "\(tsMs)-\(target.key.name)"
                    pendingTimeoutEventIds.insert(evId)
                    pendingTimeoutBuffer.append(NodeProbeSample(tsMs: tsMs, node: target.key.name, dialer: target.key.dialer,
                                                                nodeType: target.nodeType, delayMs: 0, ok: false, source: .active))
                    recentResults.insert(NodeProbeLiveEvent(id: evId, node: target.key.name,
                                                            groupName: nil, ok: false, delayMs: 0, tsMs: tsMs), at: 0)
                case .notFound:
                    totalCompleted += 1
                case .cancelled:
                    break
                case .controllerUnavailable, .authFailed:
                    discardPendingTimeouts()
                    abortedByController = true
                    group.cancelAll()
                }
                if recentResults.count > 6 { recentResults = Array(recentResults.prefix(6)) }

                // 增量刷盘 1：在线样本已证实本机联网，每 3 条或每 1.5 秒直接入库，页面 1-2 秒即可出数。
                let now = Date()
                if !pendingOkBuffer.isEmpty && (pendingOkBuffer.count >= 3 || now.timeIntervalSince(lastOkFlushAt) >= 1.5) {
                    let batch = pendingOkBuffer
                    pendingOkBuffer.removeAll(keepingCapacity: true)
                    lastOkFlushAt = now
                    let n = await onFlushSamples(batch)
                    if n > 0 { totalFlushed += n; flushedNow = true }
                }

                // 增量刷盘 2：超时样本达 4 条或缓冲超 4 秒时，先用 DIRECT 确认本机未断网再入库；断网则仅丢弃未确认超时并中止。
                if !abortedByController && !abortedByLocalOffline && !pendingTimeoutBuffer.isEmpty &&
                    (consecutiveTimeouts >= midRoundOfflineCheckThreshold || pendingTimeoutBuffer.count >= 4 || now.timeIntervalSince(lastTimeoutFlushAt) >= 4.0) {
                    consecutiveTimeouts = 0
                    let recheck = await checkDirectOnline(client: client, probeURL: probeURL, timeoutMs: timeoutMs,
                                                          retryOnTimeout: false, isStillValid: isStillValid)
                    switch recheck {
                    case .ok:
                        let batch = pendingTimeoutBuffer
                        pendingTimeoutBuffer.removeAll(keepingCapacity: true)
                        pendingTimeoutEventIds.removeAll()
                        lastTimeoutFlushAt = Date()
                        let n = await onFlushSamples(batch)
                        if n > 0 { totalFlushed += n; flushedNow = true }
                    case .timeout:
                        discardPendingTimeouts()
                        abortedByLocalOffline = true
                        group.cancelAll()
                    case .controllerUnavailable, .authFailed, .cancelled, .notFound:
                        discardPendingTimeouts()
                        abortedByController = true
                        group.cancelAll()
                    }
                }

                if !abortedByController, !abortedByLocalOffline, !pending.isEmpty, isStillValid() {
                    try? await Task.sleep(nanoseconds: interProbeDelayNs)
                    scheduleAvailable()
                }
                pushProgress(force: flushedNow)
            }
        }

        // 收尾：无论是否中止，已测出的 .ok 样本全部尽力刷盘不丢失；剩余超时样本仅在本机 DIRECT 复检通过后入库。
        var remaining: [NodeProbeSample] = pendingOkBuffer
        pendingOkBuffer.removeAll()

        if !abortedByController && !abortedByLocalOffline && isStillValid() && !pendingTimeoutBuffer.isEmpty {
            let tailCheck = await checkDirectOnline(client: client, probeURL: probeURL, timeoutMs: timeoutMs,
                                                    retryOnTimeout: false, isStillValid: isStillValid)
            switch tailCheck {
            case .ok:
                remaining.append(contentsOf: pendingTimeoutBuffer)
                pendingTimeoutBuffer.removeAll()
                pendingTimeoutEventIds.removeAll()
            case .timeout:
                discardPendingTimeouts()
                abortedByLocalOffline = true
            case .controllerUnavailable, .authFailed, .cancelled, .notFound:
                discardPendingTimeouts()
                abortedByController = true
            }
        } else {
            discardPendingTimeouts()
        }

        if abortedByLocalOffline {
            return ActiveRoundOutcome(
                remainingSamples: remaining,
                runInfo: NodeActiveProbeRunInfo(finishedAt: Date().timeIntervalSince1970, profileId: profileId,
                                                probed: totalFlushed + remaining.count, online: totalOnline, skippedReason: "offline"),
                finalProgress: NodeProbeLiveProgress(
                    runId: progressRunId, phase: .skippedOffline, total: totalTargets,
                    completed: totalCompleted, online: totalOnline, offline: totalOffline,
                    activeNodes: [], recentResults: recentResults,
                    flushedSamples: totalFlushed, updatedAt: Date().timeIntervalSince1970
                )
            )
        }

        if !isStillValid() || abortedByController {
            return ActiveRoundOutcome(
                remainingSamples: remaining,
                runInfo: nil,
                finalProgress: NodeProbeLiveProgress(
                    runId: progressRunId, phase: .cancelled, total: totalTargets,
                    completed: totalCompleted, online: totalOnline, offline: totalOffline,
                    activeNodes: [], recentResults: recentResults,
                    flushedSamples: totalFlushed, updatedAt: Date().timeIntervalSince1970
                )
            )
        }

        let persistedTotal = totalFlushed + remaining.count
        return ActiveRoundOutcome(
            remainingSamples: remaining,
            runInfo: NodeActiveProbeRunInfo(finishedAt: Date().timeIntervalSince1970, profileId: profileId,
                                            probed: persistedTotal, online: totalOnline, skippedReason: nil),
            finalProgress: NodeProbeLiveProgress(
                runId: progressRunId, phase: .finished, total: totalTargets,
                completed: totalCompleted, online: totalOnline, offline: totalOffline,
                activeNodes: [], recentResults: recentResults,
                flushedSamples: totalFlushed, updatedAt: Date().timeIntervalSince1970
            )
        )
    }
}
