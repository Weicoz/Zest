//
//  BettboxClient.swift
//  Zest
//
//  读取本机 Clash / Mihomo 系列客户端（Bettbox、Clash Verge Rev、Mihomo Party / Clash Party、
//  FlClash、ClashX 系列、mihomo CLI、自定义路径）配置里的控制器地址和 secret，
//  请求本机 Mihomo REST API（/connections、/proxies、/proxies/{name}/delay）。
//  secret 只在内存：不写日志、文件、UserDefaults，也不出现在任何错误状态里。
//  只连回环地址：secret 走明文 HTTP，不得发往远端。
//

import Foundation
#if canImport(AppKit)
import AppKit
#endif

enum BettboxResult {
    case available(BettboxPayload)
    case notRunning
    case configMissing
    case nonLocalController
    case authFailed
    case decodeFailed
    case cancelled
}

enum BettboxProxiesResult {
    case available(BettboxProxiesPayload)
    case notRunning
    case configMissing
    case nonLocalController
    case authFailed
    case decodeFailed
    case cancelled
}

enum NodeDelayResult: Equatable {
    case ok(delayMs: Int)
    case timeout
    case notFound
    case controllerUnavailable
    case authFailed
    case cancelled
}

enum BettboxConfigError: Error, Equatable {
    case missing
    case nonLocal
}

// MARK: - 代理客户端来源

/// 节点/链路监测读取本机哪一个客户端的配置。
enum ProxyClientSource: String, Codable, CaseIterable, Sendable {
    case auto
    case bettbox
    case clashVerge
    case mihomoParty
    case flClash
    case clashX
    case mihomo
    case custom

    /// 兼容 `mihomo-party`、`clash-party`、`clash-verge`、`fl-clash`、`clashx` 等写法。
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ProxyClientSource(normalized: raw)
    }

    init(normalized raw: String) {
        let key = raw.replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .lowercased()
        switch key {
        case "bettbox": self = .bettbox
        case "clashverge", "clashvergerev": self = .clashVerge
        case "mihomoparty", "clashparty": self = .mihomoParty
        case "flclash": self = .flClash
        case "clashx", "clashxmeta", "clashxpro": self = .clashX
        case "mihomo": self = .mihomo
        case "custom": self = .custom
        default: self = .auto
        }
    }

    /// 稳定的来源标识：用于 `NodeProbeScope` 键、指纹与 `<sourceId>:default` 兜底 profileId。
    var sourceId: String {
        switch self {
        case .auto: return "auto"
        case .bettbox: return "bettbox"
        case .clashVerge: return "clash-verge"
        case .mihomoParty: return "mihomo-party"
        case .flClash: return "fl-clash"
        case .clashX: return "clashx"
        case .mihomo: return "mihomo"
        case .custom: return "custom"
        }
    }

    /// 界面展示名（品牌名不翻译）。
    var displayName: String {
        switch self {
        case .auto: return "自动检测"
        case .bettbox: return "Bettbox"
        case .clashVerge: return "Clash Verge"
        case .mihomoParty: return "Mihomo Party"
        case .flClash: return "FlClash"
        case .clashX: return "ClashX"
        case .mihomo: return "Clash / Mihomo"
        case .custom: return "自定义配置"
        }
    }

    /// 判定客户端是否在运行时比对的 bundle identifier。
    var runningBundleIdentifiers: [String] {
        switch self {
        case .bettbox: return ["com.appshub.bettbox"]
        case .clashVerge: return ["io.github.clash-verge-rev.clash-verge-rev"]
        case .mihomoParty: return ["party.mihomo.app", "party.clash.app", "com.mihomo.party"]
        case .flClash: return ["com.follow.clash"]
        case .clashX: return ["com.metacubex.ClashX.meta", "com.west2online.ClashXPro", "com.metacubex.ClashX"]
        case .auto, .mihomo, .custom: return []
        }
    }

    /// 运行中应用名匹配（bundle id 随发行版变化时兜底）。
    var runningNameHints: [String] {
        switch self {
        case .bettbox: return ["bettbox"]
        case .clashVerge: return ["clash verge"]
        case .mihomoParty: return ["mihomo party", "clash party"]
        case .flClash: return ["flclash"]
        case .clashX: return ["clashx"]
        case .auto, .mihomo, .custom: return []
        }
    }
}

extension ProxyClientSource {
    /// 界面展示名：自动 / 自定义走本地化，品牌名原样。
    var localizedDisplayName: String {
        switch self {
        case .auto: return L10n.text("nodes.source.auto", defaultValue: "自动检测")
        case .custom: return L10n.text("nodes.source.custom", defaultValue: "自定义配置")
        default: return displayName
        }
    }

    /// 来源是否在运行（只读进程表，开销极低，不阻塞主线程）。
    func isRunning() -> Bool {
        let bundles = runningBundleIdentifiers
        let hints = runningNameHints
        guard !bundles.isEmpty || !hints.isEmpty else { return false }
        #if canImport(AppKit)
        for bundle in bundles {
            if !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty { return true }
        }
        for app in NSWorkspace.shared.runningApplications {
            let name = (app.localizedName ?? "").lowercased()
            if hints.contains(where: { name.contains($0) }) { return true }
        }
        #endif
        return false
    }
}

// MARK: - 配置来源定位

enum ProxyProfileKind: Equatable, Sendable {
    /// Bettbox：`config.json` 的 `currentProfileId` + `profiles[].label`
    case bettboxJSON
    /// `profiles.yaml` / `profile.yaml` 的 `current`
    case yamlCurrent
    /// FlClash：`config.json` 的 `currentProfileId` / `current`
    case flClashJSON
    case none
}

struct ProxyConfigCandidate: Equatable, Sendable {
    var source: ProxyClientSource
    var sourceId: String
    var configURL: URL
    var profileURL: URL?
    var profileKind: ProxyProfileKind
    /// 配置文件修改时间（自动检测「最近修改」用）。
    var modified: Date
}

struct ResolvedProxyConfig: Equatable, Sendable {
    var source: ProxyClientSource
    var sourceId: String
    var configURL: URL
    var profileURL: URL?
    var profileKind: ProxyProfileKind
    var text: String
    var modified: Date
}

struct BettboxClient {
    static let appSupportDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.appshub.bettbox", isDirectory: true)
    static let configURL = appSupportDirectory.appendingPathComponent("config.yaml")
    static let appConfigURL = appSupportDirectory.appendingPathComponent("config.json")

    static let defaultProbeURL = "http://cp.cloudflare.com/generate_204"
    static let defaultProbeTimeoutMs = 4000

    /// RFC 3986 unreserved 字符集：确保节点名里的空格、emoji、中文、`|`、`→`、`/` 等全部安全编码。
    private static let pathSegmentAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    /// 专用回环直连 URLSession：显式禁用系统代理与 PAC，防止系统代理配置异常劫持 127.0.0.1 控制器请求。
    private static let loopbackSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        return URLSession(configuration: cfg)
    }()

    private let origin: URL
    private let base: URL
    private let secret: String

    let source: ProxyClientSource
    let sourceId: String
    let configURL: URL
    /// `config.yaml` 的 `proxy-groups` 名称顺序，供 `NodeTopology` 还原 Bettbox / Clash 原序。
    let groupOrder: [String]

    // MARK: 构造

    /// 按行正则解析，不引入 YAML 依赖。0.0.0.0、::、[::] 改连 127.0.0.1；
    /// 端口须在 1…65535；主机须是 127.0.0.0/8、localhost 或 ::1。
    static func make(config: String,
                    source: ProxyClientSource = .bettbox,
                    sourceId: String = ProxyClientSource.bettbox.sourceId,
                    configURL: URL = BettboxClient.configURL) -> Result<BettboxClient, BettboxConfigError> {
        guard let controller = scalar("external-controller", in: config), !controller.isEmpty,
              let colon = controller.lastIndex(of: ":") else { return .failure(.missing) }
        var host = String(controller[..<colon]).lowercased()
        guard let port = Int(controller[controller.index(after: colon)...]), (1...65535).contains(port)
        else { return .failure(.missing) }
        if ["", "0.0.0.0", "::", "[::]"].contains(host) { host = "127.0.0.1" }
        guard isLoopback(host) else { return .failure(.nonLocal) }
        guard let origin = URL(string: "http://\(host):\(port)"),
              let url = URL(string: "http://\(host):\(port)/connections") else { return .failure(.missing) }
        return .success(BettboxClient(origin: origin,
                                      base: url,
                                      secret: scalar("secret", in: config) ?? "",
                                      source: source,
                                      sourceId: sourceId,
                                      configURL: configURL,
                                      groupOrder: groupOrder(inConfig: config)))
    }

    /// 读取配置并构造客户端。默认来源保持 Bettbox，行为与旧版一致。
    static func load(source: ProxyClientSource = .bettbox,
                     customPath: String = "") -> Result<BettboxClient, BettboxConfigError> {
        switch resolve(source: source, customPath: customPath) {
        case .failure(let error):
            return .failure(error)
        case .success(let resolved):
            return make(config: resolved.text,
                        source: resolved.source,
                        sourceId: resolved.sourceId,
                        configURL: resolved.configURL)
        }
    }

    // MARK: 来源定位

    /// 用户家目录下的候选配置（按偏好排序）。
    static func candidates(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [ProxyConfigCandidate] {
        let appSupport = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let dotConfig = home.appendingPathComponent(".config", isDirectory: true)

        func candidate(_ source: ProxyClientSource,
                       _ url: URL,
                       profile: URL? = nil,
                       kind: ProxyProfileKind = .none) -> ProxyConfigCandidate {
            ProxyConfigCandidate(source: source,
                                 sourceId: source.sourceId,
                                 configURL: url,
                                 profileURL: profile,
                                 profileKind: kind,
                                 modified: modificationDate(of: url))
        }

        let bettboxDir = appSupport.appendingPathComponent("com.appshub.bettbox", isDirectory: true)
        let vergeDir = appSupport.appendingPathComponent("io.github.clash-verge-rev.clash-verge-rev", isDirectory: true)
        let mihomoPartyDir = appSupport.appendingPathComponent("mihomo-party", isDirectory: true)
        let clashPartyDir = appSupport.appendingPathComponent("clash-party", isDirectory: true)
        let flClashDir = appSupport.appendingPathComponent("com.follow.clash", isDirectory: true)

        var result: [ProxyConfigCandidate] = [
            candidate(.bettbox,
                      bettboxDir.appendingPathComponent("config.yaml"),
                      profile: bettboxDir.appendingPathComponent("config.json"),
                      kind: .bettboxJSON),
            candidate(.clashVerge,
                      vergeDir.appendingPathComponent("clash-verge.yaml"),
                      profile: vergeDir.appendingPathComponent("profiles.yaml"),
                      kind: .yamlCurrent),
            candidate(.clashVerge,
                      vergeDir.appendingPathComponent("config.yaml"),
                      profile: vergeDir.appendingPathComponent("profiles.yaml"),
                      kind: .yamlCurrent),
            candidate(.mihomoParty,
                      mihomoPartyDir.appendingPathComponent("work/config.yaml"),
                      profile: mihomoPartyDir.appendingPathComponent("profile.yaml"),
                      kind: .yamlCurrent),
            candidate(.mihomoParty,
                      clashPartyDir.appendingPathComponent("work/config.yaml"),
                      profile: clashPartyDir.appendingPathComponent("profile.yaml"),
                      kind: .yamlCurrent),
            candidate(.flClash,
                      flClashDir.appendingPathComponent("config.yaml"),
                      profile: flClashDir.appendingPathComponent("config.json"),
                      kind: .flClashJSON),
            candidate(.clashX,
                      appSupport.appendingPathComponent("com.metacubex.ClashX.meta/config.yaml")),
            candidate(.clashX,
                      appSupport.appendingPathComponent("com.west2online.ClashXPro/config.yaml")),
            candidate(.clashX,
                      dotConfig.appendingPathComponent("clash/config.yaml")),
            candidate(.mihomo,
                      dotConfig.appendingPathComponent("mihomo/config.yaml"))
        ]
        result.removeAll { !FileManager.default.fileExists(atPath: $0.configURL.path) }
        return result
    }

    /// 解析来源到具体配置文件；`custom` 只认用户给定路径，`auto` 按运行状态/可达性/最近修改挑选。
    /// 解析后的配置快照：原文 + 策略组顺序。按 `(path, fileSignature)` 缓存，
    /// 稳态下 `resolve()` / `configFingerprint()` 只做 `stat()`，不再读盘与重跑解析。
    struct ProxyConfigSnapshot {
        let text: String
        let groupOrder: [String]
    }

    private static let configSnapshotLock = NSLock()
    private static var configSnapshotCache: [String: (sig: String, result: Result<ProxyConfigSnapshot, BettboxConfigError>)] = [:]

    /// 读取并校验配置；命中签名缓存时零读盘。`secret` 随原文只在内存中，不落任何持久化。
    static func snapshot(for candidate: ProxyConfigCandidate) -> Result<ProxyConfigSnapshot, BettboxConfigError> {
        let sig = fileSignature(candidate.configURL)
        guard sig != "-" else { return .failure(.missing) }
        let key = candidate.configURL.path
        configSnapshotLock.lock()
        if let cached = configSnapshotCache[key], cached.sig == sig {
            configSnapshotLock.unlock()
            return cached.result
        }
        configSnapshotLock.unlock()

        let result: Result<ProxyConfigSnapshot, BettboxConfigError>
        if let text = try? String(contentsOf: candidate.configURL, encoding: .utf8) {
            switch make(config: text, source: candidate.source, sourceId: candidate.sourceId, configURL: candidate.configURL) {
            case .success(let client):
                result = .success(ProxyConfigSnapshot(text: text, groupOrder: client.groupOrder))
            case .failure(let error):
                result = .failure(error)
            }
        } else {
            result = .failure(.missing)
        }
        configSnapshotLock.lock()
        if configSnapshotCache.count > 32 { configSnapshotCache.removeAll(keepingCapacity: true) }
        configSnapshotCache[key] = (sig, result)
        configSnapshotLock.unlock()
        return result
    }

    static func resolve(source: ProxyClientSource,
                        customPath: String = "",
                        home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Result<ResolvedProxyConfig, BettboxConfigError> {
        func resolved(_ candidate: ProxyConfigCandidate) -> Result<ResolvedProxyConfig, BettboxConfigError> {
            switch snapshot(for: candidate) {
            case .failure(let error):
                return .failure(error)
            case .success(let snapshot):
                return .success(ResolvedProxyConfig(source: candidate.source,
                                                    sourceId: candidate.sourceId,
                                                    configURL: candidate.configURL,
                                                    profileURL: candidate.profileURL,
                                                    profileKind: candidate.profileKind,
                                                    text: snapshot.text,
                                                    modified: candidate.modified))
            }
        }

        if source == .custom {
            let trimmed = (customPath as NSString).expandingTildeInPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .failure(.missing) }
            let url = URL(fileURLWithPath: trimmed)
            guard FileManager.default.fileExists(atPath: url.path) else { return .failure(.missing) }
            return resolved(ProxyConfigCandidate(source: .custom,
                                                 sourceId: ProxyClientSource.custom.sourceId,
                                                 configURL: url,
                                                 profileURL: nil,
                                                 profileKind: .none,
                                                 modified: modificationDate(of: url)))
        }

        let all = candidates(home: home)
        let pool = source == .auto ? all : all.filter { $0.source == source }
        guard !pool.isEmpty else { return .failure(.missing) }

        // 逐个校验：配置必须存在且控制器合法（回环）。缺失的跳过，非回环立即报错。
        // snapshot 按 (path, fileSignature) 缓存，稳态只做 stat，不再读盘 / 重跑解析。
        var valid: [ProxyConfigCandidate] = []
        var seenNonLocal = false
        for candidate in pool {
            switch snapshot(for: candidate) {
            case .success:
                valid.append(candidate)
            case .failure(.nonLocal):
                seenNonLocal = true
            case .failure(.missing):
                continue
            }
        }
        if valid.isEmpty {
            return .failure(seenNonLocal ? .nonLocal : .missing)
        }
        if source != .auto {
            return resolved(valid[0])
        }
        guard let chosen = selectCandidate(valid,
                                           running: runningSources(),
                                           isReachable: { isControllerReachable(candidate: $0) }) else {
            return .failure(.missing)
        }
        return resolved(chosen)
    }

    /// 自动检测优先级：运行中客户端 → 控制器可达 → 最近修改。
    static func selectCandidate(_ candidates: [ProxyConfigCandidate],
                                running: Set<String>,
                                isReachable: (ProxyConfigCandidate) -> Bool) -> ProxyConfigCandidate? {
        guard !candidates.isEmpty else { return nil }
        if let runningOne = candidates.first(where: { running.contains($0.sourceId) }) {
            return runningOne
        }
        if candidates.count > 1, let reachable = candidates.first(where: isReachable) {
            return reachable
        }
        return candidates.max { $0.modified < $1.modified }
    }

    static func runningSources() -> Set<String> {
        var result = Set<String>()
        for source in ProxyClientSource.allCases where source.isRunning() {
            result.insert(source.sourceId)
        }
        return result
    }

    /// 控制器可达性缓存（15s）。同步路径只读缓存：未命中时返回 false，并在后台异步探测 `/version`
    /// 刷新缓存供下一次 tick 使用，绝不在调用线程等待网络。
    private static let reachabilityLock = NSLock()
    private static var reachabilityCache: [String: (until: Date, ok: Bool)] = [:]
    private static var reachabilityInFlight: Set<String> = []
    private static let reachabilityQueue = DispatchQueue(label: "app.zest.bettbox.reachability", qos: .utility)

    private static func isControllerReachable(candidate: ProxyConfigCandidate) -> Bool {
        let key = candidate.sourceId + "|" + candidate.configURL.path
        reachabilityLock.lock()
        if let cached = reachabilityCache[key], cached.until > Date() {
            reachabilityLock.unlock()
            return cached.ok
        }
        let shouldProbe = !reachabilityInFlight.contains(key)
        if shouldProbe { reachabilityInFlight.insert(key) }
        reachabilityLock.unlock()

        if shouldProbe {
            // 后台低开销探测（严格只连回环地址）；本次调用按「不可达」继续走最近修改兜底。
            reachabilityQueue.async {
                probeReachability(candidate: candidate, key: key)
            }
        }
        return false
    }

    private static func probeReachability(candidate: ProxyConfigCandidate, key: String) {
        guard case .success(let snapshot) = snapshot(for: candidate),
              case .success(let client) = make(config: snapshot.text,
                                              source: candidate.source,
                                              sourceId: candidate.sourceId,
                                              configURL: candidate.configURL) else {
            storeReachability(key: key, ok: false)
            return
        }
        client.probeVersion { ok in storeReachability(key: key, ok: ok) }
    }

    private static func storeReachability(key: String, ok: Bool) {
        reachabilityLock.lock()
        reachabilityCache[key] = (Date().addingTimeInterval(15), ok)
        reachabilityInFlight.remove(key)
        reachabilityLock.unlock()
    }

    /// 配置目录（kqueue 目录监听目标）。切源后随来源变化。
    static func configDirectory(source: ProxyClientSource, customPath: String = "") -> URL? {
        switch resolve(source: source, customPath: customPath) {
        case .success(let resolved): return resolved.configURL.deletingLastPathComponent()
        case .failure: return nil
        }
    }

    private static func modificationDate(of url: URL) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
    }

    // MARK: profile

    /// 读取 Bettbox 当前选中的配置 ID 与名称（config.json）。读不到或 JSON 非法时返回 nil。
    private static func loadProfileStrict(from url: URL = appConfigURL) -> BettboxProfileInfo? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let currentId = json["currentProfileId"] as? String, !currentId.isEmpty else {
            return nil
        }
        var label = ""
        if let profiles = json["profiles"] as? [[String: Any]] {
            for item in profiles where (item["id"] as? String) == currentId {
                label = (item["label"] as? String) ?? ""
                break
            }
        }
        return BettboxProfileInfo(id: currentId, label: label)
    }

    /// 读取 Bettbox 当前选中的配置 ID 与名称（config.json）。读不到时退回 `.fallback`。
    static func loadProfile(from url: URL = appConfigURL) -> BettboxProfileInfo {
        loadProfileStrict(from: url) ?? .fallback
    }

    /// 按来源读取 profile：Bettbox 沿用 `currentProfileId`（不破坏既有 `nodeProbeScopes` 与 `group_watch`），
    /// 其他客户端用各自 profile 文件的 ID，读不到时退回 `<sourceId>:default` 以避免与 Bettbox `default` 冲突。
    static func profile(for resolved: ResolvedProxyConfig) -> BettboxProfileInfo {
        var id: String?
        var label = ""
        if let url = resolved.profileURL {
            let parsed = cachedProfileInfo(from: url, kind: resolved.profileKind)
            id = parsed.id
            label = parsed.label
        }
        if let id, !id.isEmpty {
            return BettboxProfileInfo(id: id, label: label)
        }
        if resolved.source == .bettbox { return .fallback }
        return BettboxProfileInfo(id: "\(resolved.sourceId):default", label: "")
    }

    /// profile 文件解析结果按 `(path, fileSignature)` 缓存，稳态只做 stat。
    private static let profileInfoLock = NSLock()
    private static var profileInfoCache: [String: (sig: String, id: String?, label: String)] = [:]

    private static func cachedProfileInfo(from url: URL, kind: ProxyProfileKind) -> (id: String?, label: String) {
        let sig = fileSignature(url)
        let key = url.path
        profileInfoLock.lock()
        if let cached = profileInfoCache[key], cached.sig == sig {
            profileInfoLock.unlock()
            return (cached.id, cached.label)
        }
        profileInfoLock.unlock()

        var id: String?
        var label = ""
        switch kind {
        case .bettboxJSON, .flClashJSON:
            if let data = try? Data(contentsOf: url),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                id = (json["currentProfileId"] as? String) ?? (json["current"] as? String)
                if let profiles = json["profiles"] as? [[String: Any]] {
                    for item in profiles where (item["id"] as? String) == id {
                        label = (item["label"] as? String) ?? (item["name"] as? String) ?? ""
                        break
                    }
                }
            }
        case .yamlCurrent:
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                id = scalar("current", in: text)
                label = yamlProfileName(for: id, in: text) ?? ""
            }
        case .none:
            break
        }
        profileInfoLock.lock()
        if profileInfoCache.count > 16 { profileInfoCache.removeAll(keepingCapacity: true) }
        profileInfoCache[key] = (sig, id, label)
        profileInfoLock.unlock()
        return (id, label)
    }

    /// 当前来源展示名（10 秒缓存，避免 SwiftUI 每次渲染都读配置文件）。
    static func currentDisplayName() -> String {
        let source = AppSettings.currentProxySource()
        let customPath = AppSettings.currentProxyCustomPath()
        let key = "\(source.rawValue)|\(customPath)"
        displayNameLock.lock()
        let cached = displayNameCache
        displayNameLock.unlock()
        if let cached, cached.key == key, Date().timeIntervalSince(cached.at) < 10 {
            return cached.name
        }
        let name = resolvedDisplayName(source: source, customPath: customPath)
        displayNameLock.lock()
        displayNameCache = (key, name, Date())
        displayNameLock.unlock()
        return name
    }

    private static let displayNameLock = NSLock()
    nonisolated(unsafe) private static var displayNameCache: (key: String, name: String, at: Date)?

    /// 当前来源的 profile（Bettbox 沿用 `currentProfileId`，其余用各自 profile 文件或 `<sourceId>:default`）。
    static func profile(source: ProxyClientSource, customPath: String = "") -> BettboxProfileInfo {
        switch resolve(source: source, customPath: customPath) {
        case .success(let resolved):
            return profile(for: resolved)
        case .failure:
            return source == .bettbox
                ? .fallback
                : BettboxProfileInfo(id: "\(source.sourceId):default", label: "")
        }
    }

    /// `profiles.yaml` / `profile.yaml` 里按 `uid`（或 `id`）找 `name`（Clash Verge / Mihomo Party）。
    private static func yamlProfileName(for id: String?, in text: String) -> String? {
        guard let id, !id.isEmpty else { return nil }
        var matched = false
        for rawLine in yamlLines(of: text) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            var body = trimmed
            if body.hasPrefix("-") { body = String(body.dropFirst()).trimmingCharacters(in: .whitespaces) }
            if body.hasPrefix("uid:") || body.hasPrefix("id:") {
                let key = body.hasPrefix("uid:") ? "uid:" : "id:"
                let value = yamlUnquote(String(body.dropFirst(key.count)).trimmingCharacters(in: .whitespaces))
                matched = (value == id)
            } else if matched, body.hasPrefix("name:") {
                return yamlUnquote(String(body.dropFirst("name:".count)).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    /// 缓存 profile 文件的 (sec:nsec:ino:size) -> id，避免活跃探测期间重复解析。
    private static let profileIdCacheLock = NSLock()
    private static var profileIdCache: [String: (sig: String, id: String)] = [:]

    static func fileSignature(_ url: URL) -> String {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return "-" }
        return "\(st.st_mtimespec.tv_sec):\(st.st_mtimespec.tv_nsec):\(st.st_ino):\(st.st_size)"
    }

    /// 极轻量的配置文件指纹：取 `config.yaml` 的纳秒 mtime+inode+size 与 profileId。
    /// 不依赖 profile 文件原始 mtime，防止客户端写入窗口状态等 UI 字段时误取消正在进行的主动测速；
    /// 同时仅在解析成功且读前后文件签名一致时写入缓存，避免非原子半写毒化缓存。
    static func configFingerprint(config: URL = configURL, appConfig: URL = appConfigURL) -> String {
        let appSig = fileSignature(appConfig)
        let appPath = appConfig.path
        let profileId: String
        if appSig == "-" {
            profileId = BettboxProfileInfo.fallback.id
        } else {
            profileIdCacheLock.lock()
            let cached = profileIdCache[appPath]
            profileIdCacheLock.unlock()
            if let cached, cached.sig == appSig {
                profileId = cached.id
            } else if let loaded = loadProfileStrict(from: appConfig) {
                if fileSignature(appConfig) == appSig {
                    profileIdCacheLock.lock()
                    profileIdCache[appPath] = (appSig, loaded.id)
                    profileIdCacheLock.unlock()
                }
                profileId = loaded.id
            } else {
                profileId = BettboxProfileInfo.fallback.id
            }
        }
        return "\(fileSignature(config))|\(profileId)"
    }

    /// 来源感知的指纹：当前来源标识 + 配置文件签名 + profileId。切换来源或热切配置都会变化。
    static func configFingerprint(forSource source: ProxyClientSource, customPath: String = "") -> String {
        guard case .success(let resolved) = resolve(source: source, customPath: customPath) else {
            return "missing|\(source.rawValue)"
        }
        let profileId = profile(for: resolved).id
        return "\(source.rawValue)|\(resolved.sourceId)|\(fileSignature(resolved.configURL))|\(profileId)"
    }

    static func resolvedDisplayName(source: ProxyClientSource,
                                    customPath: String = "",
                                    home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        if source == .custom { return source.localizedDisplayName }
        guard source == .auto else { return source.displayName }
        if case .success(let resolved) = resolve(source: source, customPath: customPath, home: home) {
            return resolved.source.displayName
        }
        // 自动检测失败时用通用名称，避免界面出现「找不到 自动检测 配置」这类中英混杂文案。
        return "Clash / Bettbox"
    }

    // MARK: 配置解析辅助

    /// `proxy-groups` 下的 `name` 顺序（Bettbox / Clash 原序），供策略组排序。
    static func groupOrder(inConfig text: String) -> [String] {
        var result: [String] = []
        var inside = false
        for rawLine in yamlLines(of: text) {
            let line = String(rawLine)
            // `.whitespacesAndNewlines` 兼容 CRLF：去掉行尾 `\r` 后再判断缩进与注释。
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                if inside { break }
                inside = trimmed.hasPrefix("proxy-groups:")
                continue
            }
            guard inside else { continue }
            // `- name: xxx` 或列表项内的 `name: xxx`
            var body = trimmed
            if body.hasPrefix("-") { body = String(body.dropFirst()).trimmingCharacters(in: .whitespaces) }
            guard body.hasPrefix("name:") else { continue }
            let value = String(body.dropFirst("name:".count)).trimmingCharacters(in: .whitespaces)
            if let name = yamlUnquote(value), !name.isEmpty, !result.contains(name) {
                result.append(name)
            }
        }
        return result
    }

    /// YAML 逐行切分：Swift 把 `\r\n` 视为单个 Character，直接 split("\n") 会漏切，
    /// 这里先归一化换行再切，避免 CRLF 配置解析不到策略组 / profile。
    private static func yamlLines(of text: String) -> [Substring] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
    }

    private static func yamlUnquote(_ value: String) -> String? {
        guard !value.isEmpty else { return nil }
        if let q = value.first, q == "\"" || q == "'" {
            let rest = value.dropFirst()
            if let end = rest.firstIndex(of: q) { return String(rest[..<end]) }
        }
        return (value.range(of: " #").map { String(value[..<$0.lowerBound]) } ?? value)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func isLoopback(_ host: String) -> Bool {
        if host == "localhost" || host == "[::1]" || host == "::1" { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false } && octets[0] == "127"
    }

    /// YAML 标量：引号包裹取引号内全文（不处理转义，shortcut: 含引号的值需要时再补）；
    /// 未加引号时去掉 " #" 之后的行尾注释。
    static func scalar(_ key: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "^\(key):[ \\t]*(.*)$", options: .anchorsMatchLines),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        let v = text[r].trimmingCharacters(in: .whitespacesAndNewlines)
        if let q = v.first, q == "\"" || q == "'" {
            let rest = v.dropFirst()
            if let end = rest.firstIndex(of: q) { return String(rest[..<end]) }
        }
        return (v.range(of: " #").map { String(v[..<$0.lowerBound]) } ?? v)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private init(origin: URL, base: URL, secret: String,
                 source: ProxyClientSource, sourceId: String, configURL: URL, groupOrder: [String]) {
        self.origin = origin
        self.base = base
        self.secret = secret
        self.source = source
        self.sourceId = sourceId
        self.configURL = configURL
        self.groupOrder = groupOrder
    }

    private func authorizedRequest(url: URL, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if !secret.isEmpty { request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }
        return request
    }

    /// `/connections` 请求对象（只在内存里；测试从这里检查地址与认证头）。
    func request() -> URLRequest {
        authorizedRequest(url: base, timeout: 3)
    }

    func proxiesRequest() -> URLRequest {
        authorizedRequest(url: origin.appendingPathComponent("proxies"), timeout: 5)
    }

    /// 构造 `GET /proxies/{encodedName}/delay?timeout=...&url=...` 请求。
    func delayRequest(proxyName: String, probeURL: String = BettboxClient.defaultProbeURL,
                      timeoutMs: Int = BettboxClient.defaultProbeTimeoutMs) -> URLRequest? {
        guard !proxyName.isEmpty, proxyName != ".", proxyName != "..",
              let encodedName = proxyName.addingPercentEncoding(withAllowedCharacters: Self.pathSegmentAllowed),
              var comps = URLComponents(url: origin, resolvingAgainstBaseURL: false) else { return nil }
        let clampedTimeout = max(500, min(timeoutMs, 15_000))
        comps.percentEncodedPath = "/proxies/\(encodedName)/delay"
        comps.queryItems = [
            URLQueryItem(name: "timeout", value: String(clampedTimeout)),
            URLQueryItem(name: "url", value: probeURL)
        ]
        guard let url = comps.url else { return nil }
        return authorizedRequest(url: url, timeout: TimeInterval(clampedTimeout) / 1000.0 + 2.5)
    }

    /// 异步探测 `/version`（后台自动检测用，0.4s 超时，仅走回环会话）。绝不阻塞调用线程。
    func probeVersion(completion: @escaping (Bool) -> Void) {
        var request = authorizedRequest(url: origin.appendingPathComponent("version"), timeout: 0.4)
        request.httpMethod = "GET"
        let task = Self.loopbackSession.dataTask(with: request) { _, response, _ in
            completion((response as? HTTPURLResponse)?.statusCode == 200)
        }
        task.resume()
    }

    func fetch() async -> BettboxResult {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await Self.loopbackSession.data(for: request())
        } catch is CancellationError {
            return .cancelled
        } catch let e as URLError where e.code == .cancelled {
            return .cancelled
        } catch {
            return .notRunning
        }
        guard let http = response as? HTTPURLResponse else { return .notRunning }
        switch http.statusCode {
        case 200: break
        case 401, 403: return .authFailed
        default: return .decodeFailed
        }
        guard let payload = try? JSONDecoder().decode(BettboxPayload.self, from: data) else { return .decodeFailed }
        return .available(payload)
    }

    func fetchProxies() async -> BettboxProxiesResult {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await Self.loopbackSession.data(for: proxiesRequest())
        } catch is CancellationError {
            return .cancelled
        } catch let e as URLError where e.code == .cancelled {
            return .cancelled
        } catch {
            return .notRunning
        }
        guard let http = response as? HTTPURLResponse else { return .notRunning }
        switch http.statusCode {
        case 200: break
        case 401, 403: return .authFailed
        default: return .decodeFailed
        }
        guard let payload = try? JSONDecoder().decode(BettboxProxiesPayload.self, from: data) else { return .decodeFailed }
        return .available(payload)
    }

    func testDelay(proxyName: String, probeURL: String = BettboxClient.defaultProbeURL,
                   timeoutMs: Int = BettboxClient.defaultProbeTimeoutMs) async -> NodeDelayResult {
        guard let req = delayRequest(proxyName: proxyName, probeURL: probeURL, timeoutMs: timeoutMs) else {
            return .notFound
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await Self.loopbackSession.data(for: req)
        } catch is CancellationError {
            return .cancelled
        } catch let e as URLError where e.code == .cancelled {
            return .cancelled
        } catch let e as URLError where e.code == .timedOut {
            return .timeout
        } catch {
            return .controllerUnavailable
        }
        guard let http = response as? HTTPURLResponse else { return .controllerUnavailable }
        switch http.statusCode {
        case 200:
            struct DelayBody: Decodable { var delay: Int }
            // 严格要求 0 < delay < clampedTimeout：排除 Mihomo unified-delay 超时边界返回的 4000/5000ms 假在线值。
            let clampedTimeout = max(500, min(timeoutMs, 15_000))
            if let body = try? JSONDecoder().decode(DelayBody.self, from: data),
               body.delay > 0, body.delay < clampedTimeout {
                return .ok(delayMs: body.delay)
            }
            return .timeout
        case 401, 403:
            return .authFailed
        case 408, 500, 502, 503, 504:
            // Mihomo 节点测速超时或建连失败返回 503/504/408（控制器本身在线）。
            return .timeout
        case 400...499:
            // 404 等表示节点已被删除或改名，不计为离线。
            return .notFound
        default:
            return .timeout
        }
    }
}
