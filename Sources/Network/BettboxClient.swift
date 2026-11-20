//
//  BettboxClient.swift
//  Zest
//
//  读取 Bettbox 配置里的控制器地址和 secret，请求 GET /connections。
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

enum BettboxConfigError: Error, Equatable {
    case missing
    case nonLocal
}

struct BettboxClient {
    static let configURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.appshub.bettbox/config.yaml")

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
        guard let url = URL(string: "http://\(host):\(port)/connections") else { return .failure(.missing) }
        return .success(BettboxClient(base: url, secret: scalar("secret", in: config) ?? ""))
    }

    static func load() -> Result<BettboxClient, BettboxConfigError> {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return .failure(.missing) }
        return make(config: text)
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

    private init(base: URL, secret: String) {
        self.base = base
        self.secret = secret
    }

    /// 请求对象只在内存里；测试从这里检查地址与认证头。
    func request() -> URLRequest {
        var request = URLRequest(url: base, timeoutInterval: 3)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if !secret.isEmpty { request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }
        return request
    }

    func fetch() async -> BettboxResult {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request())
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
}
