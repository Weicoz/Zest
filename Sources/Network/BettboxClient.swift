//
//  BettboxClient.swift
//  Zest
//
//  读取 Bettbox 配置里的控制器地址和 secret，请求 GET /connections。
//  secret 只在内存：不写日志、文件、UserDefaults，也不出现在任何错误状态里。
//

import Foundation

enum BettboxResult {
    case available(BettboxPayload)
    case notRunning
    case configMissing
    case authFailed
    case decodeFailed
}

struct BettboxClient {
    static let configURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.appshub.bettbox/config.yaml")

    private let base: URL
    private let secret: String

    /// 按行正则解析，不引入 YAML 依赖。读不到 external-controller 返回 nil。
    init?(config: String) {
        guard let controller = Self.value("external-controller", in: config), !controller.isEmpty,
              let colon = controller.lastIndex(of: ":") else { return nil }
        var host = String(controller[..<colon])
        let port = String(controller[controller.index(after: colon)...])
        // 通配监听地址只能从本机连 127.0.0.1。
        if ["", "0.0.0.0", "::", "[::]"].contains(host) { host = "127.0.0.1" }
        guard Int(port) != nil, let url = URL(string: "http://\(host):\(port)/connections") else { return nil }
        base = url
        secret = Self.value("secret", in: config) ?? ""
    }

    static func load() -> BettboxClient? {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return nil }
        return BettboxClient(config: text)
    }

    private static func value(_ key: String, in text: String) -> String? {
        let pattern = "^\(key):[ \\t]*[\"']?([^\"'\\n]*)"
        guard let re = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        // 未加引号时 " #" 之后是 YAML 注释。
        let v = text[r]
        return (v.range(of: " #").map { String(v[..<$0.lowerBound]) } ?? String(v)).trimmingCharacters(in: .whitespaces)
    }

    func fetch() async -> BettboxResult {
        var request = URLRequest(url: base, timeoutInterval: 3)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if !secret.isEmpty { request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return .notRunning }
        switch http.statusCode {
        case 200: break
        case 401, 403: return .authFailed
        default: return .decodeFailed
        }
        guard let payload = try? JSONDecoder().decode(BettboxPayload.self, from: data) else { return .decodeFailed }
        return .available(payload)
    }
}
