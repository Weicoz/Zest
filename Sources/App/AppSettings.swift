//
//  AppSettings.swift
//  Zest
//

import Foundation
import ServiceManagement

enum MenuBarItem: String, CaseIterable, Codable, Identifiable {
    case cpu, memory, network, temperature, disk, fan

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return L10n.text("CPU 使用率")
        case .memory: return L10n.text("内存占用")
        case .network: return L10n.text("网络速度")
        case .temperature: return L10n.text("CPU 温度")
        case .disk: return L10n.text("磁盘占用")
        case .fan: return L10n.text("风扇转速")
        }
    }

    var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .network: return "arrow.up.arrow.down"
        case .temperature: return "thermometer"
        case .disk: return "internaldrive"
        case .fan: return "fanblades"
        }
    }

    var needsSensors: Bool { self == .temperature || self == .fan }
}

struct MenuBarEntry: Codable, Identifiable, Equatable {
    var item: MenuBarItem
    var enabled: Bool
    var id: String { item.rawValue }
}

final class AppSettings: ObservableObject {
    static let refreshChoices: [Double] = [0.5, 1, 2, 3, 5, 10]
    static let nodeProbeIntervalChoices: [Int] = [5, 10, 15, 30]
    /// 分组当前出口探测间隔默认值（分钟），兼容既有 5 分钟行为。
    static let defaultNodeGroupWatchIntervalMinutes = 5
    /// 分组当前出口探测间隔（分钟）：1/2/5/10/15/30，主定时器每 60 秒唤醒一次。
    static let nodeGroupWatchIntervalChoices: [Int] = [1, 2, 5, 10, 15, 30]
    static let languageChangedNotification = Notification.Name("app.zest.monitor.language")
    static let nodeProbeSettingsChangedNotification = Notification.Name("app.zest.monitor.nodeProbeSettings")

    private let defaults: UserDefaults
    private var isApplyingRemoteLanguage = false
    private var isApplyingRemoteNodeProbe = false

    @Published var refreshInterval: Double { didSet { defaults.set(refreshInterval, forKey: Keys.interval) } }
    @Published var menuBarEntries: [MenuBarEntry] { didSet { saveEntries() } }
    @Published var temperatureUnit: TemperatureUnit { didSet { defaults.set(temperatureUnit.rawValue, forKey: Keys.unit) } }
    @Published var launchAtLoginError: String?
    @Published var toolEntries: [ToolEntry] {
        didSet { if let data = try? JSONEncoder().encode(toolEntries) { defaults.set(data, forKey: Keys.tools) } }
    }
    @Published var awakeMinutes: Int { didSet { defaults.set(awakeMinutes, forKey: Keys.awakeMinutes) } }
    @Published var cleaningSeconds: Int { didSet { defaults.set(cleaningSeconds, forKey: Keys.cleaningSeconds) } }
    @Published var dockDisplayID: UInt32 { didSet { defaults.set(Int(dockDisplayID), forKey: Keys.dockDisplayID) } }
    @Published var appLanguage: AppLanguage {
        didSet {
            guard appLanguage != oldValue else { return }
            defaults.set(appLanguage.rawValue, forKey: Keys.appLanguage)
            L10n.use(appLanguage)
            guard !isApplyingRemoteLanguage else { return }
            DistributedNotificationCenter.default().postNotificationName(
                AppSettings.languageChangedNotification, object: nil,
                userInfo: ["appLanguage": appLanguage.rawValue], deliverImmediately: true)
        }
    }

    // 网络监控
    @Published var networkMonitoring: Bool { didSet { defaults.set(networkMonitoring, forKey: Keys.networkMonitoring) } }
    @Published var resolveHostnames: Bool { didSet { defaults.set(resolveHostnames, forKey: Keys.resolveHostnames) } }
    @Published var alertNotifications: Bool { didSet { defaults.set(alertNotifications, forKey: Keys.alertNotifications) } }
    /// 写入提醒阈值（GB），0 关闭该档。
    @Published var writeAlertHourGB: Int { didSet { defaults.set(writeAlertHourGB, forKey: Keys.writeAlertHourGB) } }
    @Published var writeAlertDayGB: Int { didSet { defaults.set(writeAlertDayGB, forKey: Keys.writeAlertDayGB) } }
    @Published var suppressions: [SuppressionRule] {
        didSet { if let d = try? JSONEncoder().encode(suppressions) { defaults.set(d, forKey: Keys.suppressions) } }
    }

    // 节点监测（主动探测按 Bettbox profileId 隔离保存）
    @Published var nodeActiveProbeEnabled: Bool {
        didSet {
            guard nodeActiveProbeEnabled != oldValue else { return }
            defaults.set(nodeActiveProbeEnabled, forKey: Keys.nodeActiveProbeEnabled)
            broadcastNodeProbeSettings()
        }
    }
    @Published var nodeProbeIntervalMinutes: Int {
        didSet {
            guard nodeProbeIntervalMinutes != oldValue else { return }
            defaults.set(nodeProbeIntervalMinutes, forKey: Keys.nodeProbeIntervalMinutes)
            broadcastNodeProbeSettings()
        }
    }
    @Published var nodeProbeScopes: [String: NodeProbeScope] {
        didSet {
            guard nodeProbeScopes != oldValue else { return }
            if let d = try? JSONEncoder().encode(nodeProbeScopes) { defaults.set(d, forKey: Keys.nodeProbeScopes) }
            broadcastNodeProbeSettings()
        }
    }
    /// 选定分组当前出口连续 2 次超时时发送系统通知。
    @Published var nodeGroupAlertEnabled: Bool {
        didSet {
            guard nodeGroupAlertEnabled != oldValue else { return }
            defaults.set(nodeGroupAlertEnabled, forKey: Keys.nodeGroupAlertEnabled)
            broadcastNodeProbeSettings()
        }
    }
    /// 分组当前出口探测间隔（分钟），默认 5 分钟。
    @Published var nodeGroupWatchIntervalMinutes: Int {
        didSet {
            guard nodeGroupWatchIntervalMinutes != oldValue else { return }
            defaults.set(nodeGroupWatchIntervalMinutes, forKey: Keys.nodeGroupWatchIntervalMinutes)
            broadcastNodeProbeSettings()
        }
    }
    /// 节点/链路监测读取哪个本机客户端配置（auto 自动检测）。
    @Published var proxyClientSource: ProxyClientSource {
        didSet {
            guard proxyClientSource != oldValue else { return }
            defaults.set(proxyClientSource.rawValue, forKey: Keys.proxyClientSource)
            broadcastNodeProbeSettings()
        }
    }
    /// 自定义 `config.yaml` 路径（仅 `proxyClientSource == .custom` 时读取，支持 `~`）。
    @Published var proxyCustomConfigPath: String {
        didSet {
            guard proxyCustomConfigPath != oldValue else { return }
            defaults.set(proxyCustomConfigPath, forKey: Keys.proxyCustomConfigPath)
            broadcastNodeProbeSettings()
        }
    }
    /// 自定义趋势分组方案（正则自动提取 / 自由组合规则：正则、策略组、指定节点、链式筛选）。仅 UI 窗口读取，零后台开销。
    @Published var nodeTrendGroupSets: [NodeTrendGroupSet] {
        didSet {
            guard nodeTrendGroupSets != oldValue else { return }
            if let d = try? JSONEncoder().encode(nodeTrendGroupSets) { defaults.set(d, forKey: Keys.nodeTrendGroupSets) }
        }
    }

    /// 跨线程 / 跨进程读取当前代理客户端来源（UserDefaults 线程安全，写入即持久化）。
    static func currentProxySource(defaults: UserDefaults = .standard) -> ProxyClientSource {
        ProxyClientSource(normalized: defaults.string(forKey: Keys.proxyClientSource) ?? "auto")
    }

    /// 跨线程 / 跨进程读取自定义 `config.yaml` 路径。
    static func currentProxyCustomPath(defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: Keys.proxyCustomConfigPath) ?? ""
    }

    private enum Keys {
        static let interval = "refreshInterval"
        static let entries = "menuBarEntries"
        static let unit = "temperatureUnit"
        static let networkMonitoring = "networkMonitoring"
        static let resolveHostnames = "resolveHostnames"
        static let alertNotifications = "alertNotifications"
        static let suppressions = "alertSuppressions"
        static let appLanguage = "appLanguage"
        static let writeAlertHourGB = "writeAlertHourGB"
        static let writeAlertDayGB = "writeAlertDayGB"
        static let tools = "quickToolEntries"
        static let awakeMinutes = "toolsAwakeMinutes"
        static let cleaningSeconds = "toolsCleaningSeconds"
        static let dockDisplayID = "toolsDockDisplayID"
        static let nodeActiveProbeEnabled = "nodeActiveProbeEnabled"
        static let nodeProbeIntervalMinutes = "nodeProbeIntervalMinutes"
        static let nodeProbeScopes = "nodeProbeScopes"
        static let nodeGroupAlertEnabled = "nodeGroupAlertEnabled"
        static let nodeTrendGroupSets = "nodeTrendGroupSets"
        static let nodeGroupWatchIntervalMinutes = "nodeGroupWatchIntervalMinutes"
        static let proxyClientSource = "proxyClientSource"
        static let proxyCustomConfigPath = "proxyCustomConfigPath"
    }

    static let defaultEntries: [MenuBarEntry] = [
        .init(item: .cpu, enabled: true),
        .init(item: .memory, enabled: true),
        .init(item: .disk, enabled: true),
        .init(item: .network, enabled: true),
        .init(item: .temperature, enabled: false),
        .init(item: .fan, enabled: false),
    ]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        toolEntries = ToolEntry.load(defaults.data(forKey: Keys.tools))
        let minutes = defaults.object(forKey: Keys.awakeMinutes) as? Int ?? 30
        awakeMinutes = [0, 15, 30, 60, 120].contains(minutes) ? minutes : 30
        let seconds = defaults.integer(forKey: Keys.cleaningSeconds)
        cleaningSeconds = [30, 60, 120].contains(seconds) ? seconds : 60
        dockDisplayID = UInt32(clamping: defaults.integer(forKey: Keys.dockDisplayID))
        let interval = defaults.double(forKey: Keys.interval)
        refreshInterval = AppSettings.refreshChoices.contains(interval) ? interval : 1
        temperatureUnit = TemperatureUnit(rawValue: defaults.string(forKey: Keys.unit) ?? "") ?? .celsius
        menuBarEntries = AppSettings.loadEntries(defaults.data(forKey: Keys.entries))
        networkMonitoring = defaults.object(forKey: Keys.networkMonitoring) as? Bool ?? true
        resolveHostnames = defaults.bool(forKey: Keys.resolveHostnames)
        alertNotifications = defaults.bool(forKey: Keys.alertNotifications)
        writeAlertHourGB = max(defaults.object(forKey: Keys.writeAlertHourGB) as? Int ?? 2, 0)
        writeAlertDayGB = max(defaults.object(forKey: Keys.writeAlertDayGB) as? Int ?? 10, 0)
        suppressions = defaults.data(forKey: Keys.suppressions)
            .flatMap { try? JSONDecoder().decode([SuppressionRule].self, from: $0) } ?? []
        nodeActiveProbeEnabled = defaults.bool(forKey: Keys.nodeActiveProbeEnabled)
        let probeMin = defaults.integer(forKey: Keys.nodeProbeIntervalMinutes)
        nodeProbeIntervalMinutes = AppSettings.nodeProbeIntervalChoices.contains(probeMin) ? probeMin : 10
        nodeProbeScopes = defaults.data(forKey: Keys.nodeProbeScopes)
            .flatMap { try? JSONDecoder().decode([String: NodeProbeScope].self, from: $0) } ?? [:]
        nodeGroupAlertEnabled = defaults.object(forKey: Keys.nodeGroupAlertEnabled) as? Bool ?? true
        let watchMin = defaults.integer(forKey: Keys.nodeGroupWatchIntervalMinutes)
        nodeGroupWatchIntervalMinutes = AppSettings.nodeGroupWatchIntervalChoices.contains(watchMin)
            ? watchMin : AppSettings.defaultNodeGroupWatchIntervalMinutes
        proxyClientSource = ProxyClientSource(normalized: defaults.string(forKey: Keys.proxyClientSource) ?? "auto")
        proxyCustomConfigPath = defaults.string(forKey: Keys.proxyCustomConfigPath) ?? ""
        if let rawSets = defaults.data(forKey: Keys.nodeTrendGroupSets),
           let decodedSets = try? JSONDecoder().decode([NodeTrendGroupSet].self, from: rawSets),
           !decodedSets.isEmpty {
            nodeTrendGroupSets = decodedSets
        } else {
            nodeTrendGroupSets = NodeTrendGroupSet.defaultPresets()
        }
        appLanguage = AppLanguage.stored(defaults.string(forKey: Keys.appLanguage))
        L10n.use(appLanguage)
    }

    /// 解析已保存的顺序；补齐新增项目、去掉未知项目。
    static func loadEntries(_ data: Data?) -> [MenuBarEntry] {
        guard let data, let saved = try? JSONDecoder().decode([MenuBarEntry].self, from: data) else { return defaultEntries }
        var seen = Set<MenuBarItem>()
        var result = saved.filter { seen.insert($0.item).inserted }
        for entry in defaultEntries where !seen.contains(entry.item) {
            result.append(MenuBarEntry(item: entry.item, enabled: false))
        }
        return result
    }

    private func saveEntries() {
        if let data = try? JSONEncoder().encode(menuBarEntries) { defaults.set(data, forKey: Keys.entries) }
    }

    /// 其他进程（网络监控窗口）修改了忽略规则后重新读取。
    func reloadSuppressions() {
        let fresh = defaults.data(forKey: Keys.suppressions)
            .flatMap { try? JSONDecoder().decode([SuppressionRule].self, from: $0) } ?? []
        if fresh != suppressions { suppressions = fresh }
    }

    func scope(forProfile id: String) -> NodeProbeScope {
        nodeProbeScopes[id] ?? NodeProbeScope()
    }

    func setScope(_ scope: NodeProbeScope, forProfile id: String) {
        var next = nodeProbeScopes
        if !scope.hasAnySelection { next.removeValue(forKey: id) } else { next[id] = scope }
        if next != nodeProbeScopes { nodeProbeScopes = next }
    }

    func resetNodeTrendGroupSets() {
        nodeTrendGroupSets = NodeTrendGroupSet.defaultPresets()
    }

    private struct NodeProbeSyncPayload: Codable {
        var enabled: Bool
        var intervalMinutes: Int
        var scopes: [String: NodeProbeScope]
        var groupAlertEnabled: Bool
        /// 可选：旧版 payload 缺失时按默认 5 分钟处理。
        var watchIntervalMinutes: Int?
        var proxyClientSource: String?
        var proxyCustomConfigPath: String?
    }

    func reloadNodeProbeSettings(_ note: Notification? = nil) {
        isApplyingRemoteNodeProbe = true
        defer { isApplyingRemoteNodeProbe = false }
        if let raw = note?.userInfo?["payload"] as? String,
           let data = raw.data(using: .utf8),
           let payload = try? JSONDecoder().decode(NodeProbeSyncPayload.self, from: data) {
            let interval = AppSettings.nodeProbeIntervalChoices.contains(payload.intervalMinutes) ? payload.intervalMinutes : 10
            if payload.enabled != nodeActiveProbeEnabled { nodeActiveProbeEnabled = payload.enabled }
            if interval != nodeProbeIntervalMinutes { nodeProbeIntervalMinutes = interval }
            if payload.scopes != nodeProbeScopes { nodeProbeScopes = payload.scopes }
            if payload.groupAlertEnabled != nodeGroupAlertEnabled { nodeGroupAlertEnabled = payload.groupAlertEnabled }
            let watch = payload.watchIntervalMinutes ?? 5
            let watchInterval = AppSettings.nodeGroupWatchIntervalChoices.contains(watch)
                ? watch : AppSettings.defaultNodeGroupWatchIntervalMinutes
            if watchInterval != nodeGroupWatchIntervalMinutes { nodeGroupWatchIntervalMinutes = watchInterval }
            let source = ProxyClientSource(normalized: payload.proxyClientSource ?? "auto")
            if source != proxyClientSource { proxyClientSource = source }
            let customPath = payload.proxyCustomConfigPath ?? ""
            if customPath != proxyCustomConfigPath { proxyCustomConfigPath = customPath }
            return
        }
        let enabled = defaults.bool(forKey: Keys.nodeActiveProbeEnabled)
        if enabled != nodeActiveProbeEnabled { nodeActiveProbeEnabled = enabled }
        let rawInterval = defaults.integer(forKey: Keys.nodeProbeIntervalMinutes)
        let interval = AppSettings.nodeProbeIntervalChoices.contains(rawInterval) ? rawInterval : 10
        if interval != nodeProbeIntervalMinutes { nodeProbeIntervalMinutes = interval }
        let scopes = defaults.data(forKey: Keys.nodeProbeScopes)
            .flatMap { try? JSONDecoder().decode([String: NodeProbeScope].self, from: $0) } ?? [:]
        if scopes != nodeProbeScopes { nodeProbeScopes = scopes }
        let alert = defaults.object(forKey: Keys.nodeGroupAlertEnabled) as? Bool ?? true
        if alert != nodeGroupAlertEnabled { nodeGroupAlertEnabled = alert }
        let rawWatch = defaults.integer(forKey: Keys.nodeGroupWatchIntervalMinutes)
        let watch = AppSettings.nodeGroupWatchIntervalChoices.contains(rawWatch)
            ? rawWatch : AppSettings.defaultNodeGroupWatchIntervalMinutes
        if watch != nodeGroupWatchIntervalMinutes { nodeGroupWatchIntervalMinutes = watch }
        let source = ProxyClientSource(normalized: defaults.string(forKey: Keys.proxyClientSource) ?? "auto")
        if source != proxyClientSource { proxyClientSource = source }
        let path = defaults.string(forKey: Keys.proxyCustomConfigPath) ?? ""
        if path != proxyCustomConfigPath { proxyCustomConfigPath = path }
    }

    /// 构造跨进程通知负载，规避 UserDefaults(cfprefsd) 异步同步与 distnoted 通知之间的竞态。
    func nodeProbeUserInfo() -> [AnyHashable: Any]? {
        let payload = NodeProbeSyncPayload(enabled: nodeActiveProbeEnabled,
                                           intervalMinutes: nodeProbeIntervalMinutes,
                                           scopes: nodeProbeScopes,
                                           groupAlertEnabled: nodeGroupAlertEnabled,
                                           watchIntervalMinutes: nodeGroupWatchIntervalMinutes,
                                           proxyClientSource: proxyClientSource.rawValue,
                                           proxyCustomConfigPath: proxyCustomConfigPath)
        guard let data = try? JSONEncoder().encode(payload),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return ["payload": str]
    }

    private func broadcastNodeProbeSettings() {
        guard !isApplyingRemoteNodeProbe else { return }
        DistributedNotificationCenter.default().postNotificationName(
            AppSettings.nodeProbeSettingsChangedNotification, object: nil,
            userInfo: nodeProbeUserInfo(), deliverImmediately: true)
    }

    /// 另一个进程改了界面语言。值不变则不赋值，避免再次广播。
    func reloadLanguage(_ note: Notification? = nil) {
        let raw = note?.userInfo?["appLanguage"] as? String ?? defaults.string(forKey: Keys.appLanguage)
        let fresh = AppLanguage.stored(raw)
        guard fresh != appLanguage else { return }
        isApplyingRemoteLanguage = true
        appLanguage = fresh
        isApplyingRemoteLanguage = false
    }

    var enabledItems: [MenuBarItem] { menuBarEntries.filter(\.enabled).map(\.item) }

    // MARK: 开机启动（SMAppService，macOS 13+，无需辅助程序）

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                launchAtLoginError = nil
            } catch {
                launchAtLoginError = error.localizedDescription
            }
        }
    }

    var launchAtLoginRequiresApproval: Bool { SMAppService.mainApp.status == .requiresApproval }
}
