//
//  BettboxClient.swift
//  Zest
//
//  读取 Bettbox 配置里的控制器地址和 secret，请求本机 Mihomo REST API（/connections、/proxies、/proxies/{name}/delay）。
//  secret 只在内存：不写日志、文件、UserDefaults，也不出现在任何错误状态里。
//  只连回环地址：secret 走明文 HTTP，不得发往远端。
//

import Foundation

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

    /// 按行正则解析，不引入 YAML 依赖。0.0.0.0、::、[::] 改连 127.0.0.1；
    /// 端口须在 1…65535；主机须是 127.0.0.0/8、localhost 或 ::1。
    static func make(config: String) -> Result<BettboxClient, BettboxConfigError> {
        guard let controller = scalar("external-controller", in: config), !controller.isEmpty,
              let colon = controller.lastIndex(of: ":") else { return .failure(.missing) }
        var host = String(controller[..<colon]).lowercased()
        guard let port = Int(controller[controller.index(after: colon)...]), (1...65535).contains(port)
        else { return .failure(.missing) }
        if ["", "0.0.0.0", "::", "[::]"].contains(host) { host = "127.0.0.1" }
        guard isLoopback(host) else { return .failure(.nonLocal) }
        guard let origin = URL(string: "http://\(host):\(port)"),
              let url = URL(string: "http://\(host):\(port)/connections") else { return .failure(.missing) }
        return .success(BettboxClient(origin: origin, base: url, secret: scalar("secret", in: config) ?? ""))
    }

    static func load() -> Result<BettboxClient, BettboxConfigError> {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return .failure(.missing) }
        return make(config: text)
    }

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

    /// 缓存 config.json 的 (sec:nsec:ino:size) -> currentProfileId，避免活跃探测期间重复解析 JSON。
    private static let profileIdCacheLock = NSLock()
    private static var profileIdCache: [String: (sig: String, id: String)] = [:]

    /// 极轻量的配置文件指纹：取 `config.yaml` 的纳秒 mtime+inode+size 与 `config.json` 的 `currentProfileId`。
    /// 不依赖 `config.json` 原始 mtime，防止 Bettbox 写入窗口状态等 UI 字段时误取消正在进行的主动测速；
    /// 同时仅在 JSON 解析成功且读前后文件签名一致时写入缓存，避免非原子半写毒化缓存。
    static func configFingerprint(config: URL = configURL, appConfig: URL = appConfigURL) -> String {
        func sig(_ url: URL) -> String {
            var st = stat()
            guard stat(url.path, &st) == 0 else { return "-" }
            return "\(st.st_mtimespec.tv_sec):\(st.st_mtimespec.tv_nsec):\(st.st_ino):\(st.st_size)"
        }
        let appSig = sig(appConfig)
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
                if sig(appConfig) == appSig {
                    profileIdCacheLock.lock()
                    profileIdCache[appPath] = (appSig, loaded.id)
                    profileIdCacheLock.unlock()
                }
                profileId = loaded.id
            } else {
                profileId = BettboxProfileInfo.fallback.id
            }
        }
        return "\(sig(config))|\(profileId)"
    }

    private static func isLoopback(_ host: String) -> Bool {
        if host == "localhost" || host == "[::1]" { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false } && octets[0] == "127"
    }

    /// YAML 标量：引号包裹取引号内全文（不处理转义，shortcut: 含引号的值需要时再补）；
    /// 未加引号时去掉 " #" 之后的行尾注释。
    static func scalar(_ key: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "^\(key):[ \\t]*(.*)$", options: .anchorsMatchLines),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        let v = text[r].trimmingCharacters(in: .whitespaces)
        if let q = v.first, q == "\"" || q == "'" {
            let rest = v.dropFirst()
            if let end = rest.firstIndex(of: q) { return String(rest[..<end]) }
        }
        return (v.range(of: " #").map { String(v[..<$0.lowerBound]) } ?? v).trimmingCharacters(in: .whitespaces)
    }

    private init(origin: URL, base: URL, secret: String) {
        self.origin = origin
        self.base = base
        self.secret = secret
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
