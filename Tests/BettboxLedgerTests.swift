//
//  BettboxLedgerTests.swift
//  ZestTests
//
//  接缝 A：链路账本核心。内联 JSON 合成夹具，不含真实域名、进程或 secret。
//

import XCTest
@testable import Zest

final class BettboxLedgerTests: XCTestCase {
    private func conn(_ id: String, down: Int64, up: Int64, type: String = "HTTPS", chains: String = #""node-a","group-a""#,
                      rule: String = "RuleSet", payload: String = "p1", app: String = "app1") -> String {
        """
        {"id":"\(id)","download":\(down),"upload":\(up),"chains":[\(chains)],"rule":"\(rule)","rulePayload":"\(payload)",
         "metadata":{"type":"\(type)","host":"h.example.test","destinationIP":"192.0.2.1","destinationPort":"443","process":"\(app)"}}
        """
    }

    private func payload(down: Int64, up: Int64, _ conns: [String]) throws -> BettboxPayload {
        let json = #"{"downloadTotal":\#(down),"uploadTotal":\#(up),"connections":[\#(conns.joined(separator: ","))]}"#
        return try JSONDecoder().decode(BettboxPayload.self, from: Data(json.utf8))
    }

    private let t0 = Date(timeIntervalSince1970: 1_000)
    private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    func testInnerConnectionsAreExcluded() throws {
        var l = TrafficLedger()
        l.ingest(try payload(down: 0, up: 0, [conn("a", down: 0, up: 0), conn("i", down: 0, up: 0, type: "Inner")]), at: at(0))
        l.ingest(try payload(down: 300, up: 30, [conn("a", down: 100, up: 10), conn("i", down: 200, up: 20, type: "inner")]), at: at(2))
        XCTAssertEqual(l.links.map(\.id), ["a"])
        XCTAssertEqual(l.byApp["app1"], LedgerTraffic(down: 100, up: 10))
        XCTAssertEqual(l.unattributed, LedgerTraffic(down: 200, up: 20))   // Inner 的字节只留在总量差额里
    }

    func testNewAndClosedConnections() throws {
        var l = TrafficLedger()
        l.ingest(try payload(down: 1000, up: 100, [conn("a", down: 1000, up: 100)]), at: at(0))   // 基线，不计入
        XCTAssertEqual(l.byApp["app1"], LedgerTraffic())
        l.ingest(try payload(down: 1150, up: 115, [conn("a", down: 1100, up: 100), conn("b", down: 50, up: 15)]), at: at(2))
        XCTAssertEqual(l.byApp["app1"], LedgerTraffic(down: 150, up: 15))   // a 增 100，新连接 b 从 0 起算
        XCTAssertEqual(l.links.first { $0.id == "b" }?.downRate, 25)
        l.ingest(try payload(down: 1250, up: 115, [conn("b", down: 150, up: 15)]), at: at(4))   // a 已关闭
        XCTAssertEqual(l.byApp["app1"], LedgerTraffic(down: 250, up: 15))
        XCTAssertEqual(l.links.map(\.id), ["b"])
        XCTAssertEqual(l.unattributed, LedgerTraffic())
    }

    func testCounterResetCountsFromZero() throws {
        var l = TrafficLedger()
        l.ingest(try payload(down: 500, up: 0, [conn("a", down: 500, up: 0)]), at: at(0))
        l.ingest(try payload(down: 560, up: 0, [conn("a", down: 40, up: 0)]), at: at(2))   // 同 id 累计变小
        XCTAssertEqual(l.byApp["app1"]?.down, 40)
        XCTAssertEqual(l.unattributed.down, 20)
    }

    func testBettboxRestartHasNoNegativeOrJump() throws {
        var l = TrafficLedger()
        l.ingest(try payload(down: 9_000_000, up: 800_000, [conn("a", down: 100, up: 10)]), at: at(0))
        // 重启：自报总量清零且大于逐连接之和（含已关闭连接），旧连接消失；未归属仍记 0。
        l.ingest(try payload(down: 100, up: 10, [conn("n", down: 70, up: 7)]), at: at(2))
        XCTAssertEqual(l.byApp["app1"], LedgerTraffic(down: 70, up: 7))
        XCTAssertEqual(l.unattributed, LedgerTraffic())
        l.ingest(try payload(down: 120, up: 12, [conn("n", down: 90, up: 9)]), at: at(4))
        XCTAssertEqual(l.byApp["app1"], LedgerTraffic(down: 90, up: 9))
        XCTAssertEqual(l.unattributed, LedgerTraffic())
    }

    func testNegativeUnattributedIsZero() throws {
        var l = TrafficLedger()
        l.ingest(try payload(down: 0, up: 0, [conn("a", down: 0, up: 0)]), at: at(0))
        // 逐连接增量 100 大于总量增量 60：未归属记 0，不回填。
        l.ingest(try payload(down: 60, up: 50, [conn("a", down: 100, up: 20)]), at: at(2))
        XCTAssertEqual(l.unattributed, LedgerTraffic(down: 0, up: 30))
        XCTAssertEqual(l.byApp["app1"], LedgerTraffic(down: 100, up: 20))
    }

    func testExitIsOutboundNodeAndDirectIsRecognized() throws {
        var l = TrafficLedger()
        let direct = conn("d", down: 0, up: 0, chains: #""direct""#, rule: "Match", payload: "")
        let viaGroup = conn("g", down: 0, up: 0, chains: #""node-a","group-a","group-top""#)
        l.ingest(try payload(down: 0, up: 0, [direct, viaGroup]), at: at(0))
        let d2 = conn("d", down: 10, up: 0, chains: #""direct""#, rule: "Match", payload: "")
        let g2 = conn("g", down: 20, up: 0, chains: #""node-a","group-a","group-top""#)
        l.ingest(try payload(down: 30, up: 0, [d2, g2]), at: at(2))
        XCTAssertEqual(l.byExit["DIRECT"]?.down, 10)
        XCTAssertEqual(l.byExit["node-a"]?.down, 20)
        XCTAssertEqual(l.byRule["Match"]?.down, 10)
        XCTAssertEqual(l.links.first { $0.id == "g" }?.chain, ["group-top", "group-a", "node-a"])
    }

    func testResumeAfterOutageStartsNewBaseline() throws {
        var l = TrafficLedger()
        l.ingest(try payload(down: 0, up: 0, [conn("a", down: 0, up: 0)]), at: at(0))
        l.ingest(try payload(down: 100, up: 10, [conn("a", down: 100, up: 10)]), at: at(2))
        l.interrupt()   // Bettbox 不可用
        XCTAssertTrue(l.links.isEmpty)
        XCTAssertEqual(l.byApp["app1"], LedgerTraffic(down: 100, up: 10))   // 累计保留
        // 停机期间 a 与总量都涨了；恢复后的第一份只作基线。
        l.ingest(try payload(down: 5_000, up: 500, [conn("a", down: 4_000, up: 400)]), at: at(60))
        XCTAssertEqual(l.byApp["app1"], LedgerTraffic(down: 100, up: 10))
        XCTAssertEqual(l.unattributed, LedgerTraffic())
        XCTAssertEqual(l.links.first?.downRate, 0)
        l.ingest(try payload(down: 5_050, up: 505, [conn("a", down: 4_050, up: 405)]), at: at(62))
        XCTAssertEqual(l.byApp["app1"], LedgerTraffic(down: 150, up: 15))
    }
}

final class BettboxConfigTests: XCTestCase {
    private func client(_ cfg: String) throws -> BettboxClient { try BettboxClient.make(config: cfg).get() }
    private func url(_ cfg: String) throws -> String? { try client(cfg).request().url?.absoluteString }
    private func auth(_ cfg: String) throws -> String? { try client(cfg).request().value(forHTTPHeaderField: "Authorization") }
    private func failure(_ cfg: String) -> BettboxConfigError? {
        if case .failure(let e) = BettboxClient.make(config: cfg) { return e }
        return nil
    }

    func testWildcardHostsUseLoopback() throws {
        XCTAssertEqual(try url("external-controller: 0.0.0.0:9090\n"), "http://127.0.0.1:9090/connections")
        XCTAssertEqual(try url("external-controller: ':9091'\n"), "http://127.0.0.1:9091/connections")
        XCTAssertEqual(try url("external-controller: \"[::]:9092\"\n"), "http://127.0.0.1:9092/connections")
        XCTAssertEqual(try url("external-controller: localhost:9093\n"), "http://localhost:9093/connections")
        XCTAssertEqual(try url("external-controller: 127.0.0.5:9094\n"), "http://127.0.0.5:9094/connections")
        XCTAssertEqual(try url("external-controller: '[::1]:9095'\n"), "http://[::1]:9095/connections")
    }

    func testQuotedAndCommentedValues() throws {
        let q = "external-controller: '127.0.0.1:9090' # c\nsecret: \"ab # cd\" # note\n"
        XCTAssertEqual(try auth(q), "Bearer ab # cd")
        XCTAssertEqual(try auth("external-controller: 127.0.0.1:9090 # c\nsecret: abc # note\n"), "Bearer abc")
        XCTAssertEqual(try url("external-controller: 127.0.0.1:9090 # c\n"), "http://127.0.0.1:9090/connections")
        XCTAssertNil(try auth("external-controller: 127.0.0.1:9090\nsecret: ''\n"))
        XCTAssertNil(try auth("external-controller: 127.0.0.1:9090\n"))
    }

    func testMissingControllerOrBadPort() {
        XCTAssertEqual(failure("secret: x\n"), .missing)
        XCTAssertEqual(failure("external-controller: 127.0.0.1:0\n"), .missing)
        XCTAssertEqual(failure("external-controller: 127.0.0.1:65536\n"), .missing)
        XCTAssertEqual(failure("external-controller: 127.0.0.1:abc\n"), .missing)
        XCTAssertEqual(failure("external-controller: 127.0.0.1\n"), .missing)
    }

    func testNonLoopbackIsRefused() {
        XCTAssertEqual(failure("external-controller: 192.0.2.7:9090\nsecret: x\n"), .nonLocal)
        XCTAssertEqual(failure("external-controller: ctl.example.test:9090\n"), .nonLocal)
        XCTAssertEqual(failure("external-controller: 128.0.0.1:9090\n"), .nonLocal)
        XCTAssertEqual(failure("external-controller: 127.0.0.1.example.test:9090\n"), .nonLocal)
    }
}

final class BettboxLedgerDeltaTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    private func date(_ d: Int, _ h: Int, _ m: Int, _ s: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m, second: s))!
    }

    private func payload(down: Int64, up: Int64, conn: Int64) throws -> BettboxPayload {
        let c = """
        {"id":"a","download":\(conn),"upload":0,"chains":["node-a"],"rule":"RuleSet","rulePayload":"p1",
         "metadata":{"type":"HTTPS","host":"h.example.test","destinationIP":"192.0.2.1","destinationPort":"443","process":"app1"}}
        """
        return try JSONDecoder().decode(BettboxPayload.self,
            from: Data(#"{"downloadTotal":\#(down),"uploadTotal":\#(up),"connections":[\#(c)]}"#.utf8))
    }

    func testDeltaCrossesLocalMidnight() throws {
        var l = TrafficLedger()
        l.ingest(try payload(down: 0, up: 0, conn: 0), at: date(7, 23, 59, 58), calendar: cal)
        let before = l.ingest(try payload(down: 150, up: 0, conn: 100), at: date(7, 23, 59, 59), calendar: cal)
        let after = l.ingest(try payload(down: 400, up: 0, conn: 300), at: date(8, 0, 0, 1), calendar: cal)
        let route = { (day: Int) in LedgerDelta.Route(day: day, rule: "RuleSet: p1", exit: "node-a", app: "app1") }
        XCTAssertEqual(before.routes[route(20261107)], LedgerTraffic(down: 100, up: 0))
        XCTAssertEqual(before.unattributed[20261107], LedgerTraffic(down: 50, up: 0))
        XCTAssertNil(before.routes[route(20261108)])
        XCTAssertEqual(after.routes[route(20261108)], LedgerTraffic(down: 200, up: 0))   // 本轮增量全记到采样时刻所在日
        XCTAssertEqual(after.unattributed[20261108], LedgerTraffic(down: 50, up: 0))
        XCTAssertNil(after.routes[route(20261107)])
        XCTAssertEqual(after.hours[.init(hour: 2026110800, rule: "RuleSet: p1", exit: "node-a", app: "app1")]?.down, 200)
        XCTAssertEqual(after.domains[.init(day: 20261108, host: "h.example.test", rule: "RuleSet: p1", exit: "node-a", app: "app1")]?.down, 200)
    }
}

// MARK: - 多客户端配置源（需求 2）

final class ProxyClientSourceTests: XCTestCase {
    private var home: URL!

    override func setUp() {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("zest-home-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
    }

    @discardableResult
    private func write(_ relative: String, _ text: String) -> URL {
        let url = home.appendingPathComponent(relative)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func resolved(_ source: ProxyClientSource, id: String = "x",
                          configURL: URL = URL(fileURLWithPath: "/tmp/config.yaml"),
                          profileURL: URL? = nil, kind: ProxyProfileKind = .none) -> ResolvedProxyConfig {
        ResolvedProxyConfig(source: source, sourceId: source.sourceId, configURL: configURL,
                            profileURL: profileURL, profileKind: kind,
                            text: "external-controller: 127.0.0.1:9090", modified: Date())
    }

    func testSourceNormalizationAndStableIdentifiers() {
        XCTAssertEqual(ProxyClientSource(normalized: "mihomo-party"), .mihomoParty)
        XCTAssertEqual(ProxyClientSource(normalized: "clash-party"), .mihomoParty)
        XCTAssertEqual(ProxyClientSource(normalized: "clash-verge-rev"), .clashVerge)
        XCTAssertEqual(ProxyClientSource(normalized: "ClashX"), .clashX)
        XCTAssertEqual(ProxyClientSource(normalized: "fl_clash"), .flClash)
        XCTAssertEqual(ProxyClientSource(normalized: "unknown-client"), .auto)
        XCTAssertEqual(ProxyClientSource(rawValue: "auto"), .auto)

        let ids = Set(ProxyClientSource.allCases.map(\.sourceId))
        XCTAssertEqual(ids.count, ProxyClientSource.allCases.count)
        XCTAssertEqual(ProxyClientSource.bettbox.sourceId, "bettbox")
        XCTAssertEqual(ProxyClientSource.custom.sourceId, "custom")
        XCTAssertFalse(ProxyClientSource.clashX.displayName.isEmpty)
    }

    func testCandidatesDiscoverEveryClientPath() {
        write("Library/Application Support/com.appshub.bettbox/config.yaml", "external-controller: 127.0.0.1:9090")
        write("Library/Application Support/com.appshub.bettbox/config.json", #"{"currentProfileId":"p1"}"#)
        write("Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/clash-verge.yaml",
              "external-controller: 127.0.0.1:9097")
        write("Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/profiles.yaml", "current: verge-1")
        write("Library/Application Support/mihomo-party/work/config.yaml", "external-controller: 127.0.0.1:9090")
        write("Library/Application Support/mihomo-party/profile.yaml", "current: party-1")
        write("Library/Application Support/com.follow.clash/config.yaml", "external-controller: 127.0.0.1:9090")
        write("Library/Application Support/com.metacubex.ClashX.meta/config.yaml", "external-controller: 127.0.0.1:9090")
        write(".config/clash/config.yaml", "external-controller: 127.0.0.1:7890")
        write(".config/mihomo/config.yaml", "external-controller: 127.0.0.1:9090")

        let list = BettboxClient.candidates(home: home)
        let sources = Set(list.map(\.source))
        XCTAssertTrue(sources.contains(.bettbox))
        XCTAssertTrue(sources.contains(.clashVerge))
        XCTAssertTrue(sources.contains(.mihomoParty))
        XCTAssertTrue(sources.contains(.flClash))
        XCTAssertTrue(sources.contains(.clashX))
        XCTAssertTrue(sources.contains(.mihomo))
        XCTAssertEqual(list.filter { $0.source == .mihomoParty }.count, 1)   // clash-party 未创建时不出现

        let bettbox = list.first { $0.source == .bettbox }
        XCTAssertEqual(bettbox?.profileKind, .bettboxJSON)
        XCTAssertEqual(bettbox?.sourceId, "bettbox")
        XCTAssertNotNil(bettbox?.profileURL)

        let verge = list.first { $0.source == .clashVerge }
        XCTAssertEqual(verge?.profileKind, .yamlCurrent)
        XCTAssertEqual(verge?.configURL.lastPathComponent, "clash-verge.yaml")
        XCTAssertEqual(verge?.sourceId, "clash-verge")

        // 目录里没有任何配置文件时不应返回候选。
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("zest-empty-\(UUID().uuidString)")
        XCTAssertTrue(BettboxClient.candidates(home: empty).isEmpty)
    }

    func testAutoDetectionPriorityRunningThenReachableThenNewest() {
        let old = ProxyConfigCandidate(source: .bettbox, sourceId: "bettbox",
                                       configURL: URL(fileURLWithPath: "/tmp/a.yaml"), profileURL: nil,
                                       profileKind: .none, modified: Date(timeIntervalSince1970: 100))
        let mid = ProxyConfigCandidate(source: .clashVerge, sourceId: "clash-verge",
                                       configURL: URL(fileURLWithPath: "/tmp/b.yaml"), profileURL: nil,
                                       profileKind: .none, modified: Date(timeIntervalSince1970: 200))
        let new = ProxyConfigCandidate(source: .mihomo, sourceId: "mihomo",
                                       configURL: URL(fileURLWithPath: "/tmp/c.yaml"), profileURL: nil,
                                       profileKind: .none, modified: Date(timeIntervalSince1970: 300))

        // 运行中的客户端优先于更新的配置。
        XCTAssertEqual(BettboxClient.selectCandidate([old, mid, new], running: ["bettbox"], isReachable: { _ in true }),
                       old)
        // 无运行信号时取可达者。
        XCTAssertEqual(BettboxClient.selectCandidate([old, mid, new], running: [], isReachable: { $0.source == .clashVerge }),
                       mid)
        // 都不可达时取最近修改。
        XCTAssertEqual(BettboxClient.selectCandidate([old, mid, new], running: [], isReachable: { _ in false }), new)
        XCTAssertNil(BettboxClient.selectCandidate([], running: [], isReachable: { _ in true }))
    }

    func testCustomPathResolutionAndLoopbackValidation() {
        let good = write("custom/config.yaml", "external-controller: 127.0.0.1:9090\nsecret: s3cr3t\n")
        guard case .success(let resolved) = BettboxClient.resolve(source: .custom, customPath: good.path) else {
            return XCTFail("custom path should resolve")
        }
        XCTAssertEqual(resolved.source, .custom)
        XCTAssertEqual(resolved.sourceId, "custom")
        XCTAssertEqual(resolved.configURL, good)
        XCTAssertEqual(BettboxClient.configDirectory(source: .custom, customPath: good.path)?.standardizedFileURL,
                       good.deletingLastPathComponent().standardizedFileURL)
        XCTAssertEqual(BettboxClient.profile(for: resolved).id, "custom:default")

        let remote = write("custom/remote.yaml", "external-controller: 10.1.2.3:9090\n")
        guard case .failure(let error) = BettboxClient.resolve(source: .custom, customPath: remote.path) else {
            return XCTFail("non-loopback controller must be refused")
        }
        XCTAssertEqual(error, .nonLocal)

        guard case .failure(let missing) = BettboxClient.resolve(source: .custom, customPath: "~/definitely-missing.yaml") else {
            return XCTFail("missing path must fail")
        }
        XCTAssertEqual(missing, .missing)
        if case .success = BettboxClient.load(source: .custom, customPath: "") {
            XCTFail("empty custom path must not load")
        }
        XCTAssertNil(BettboxClient.configDirectory(source: .custom, customPath: ""))

        // 自定义配置的 secret 只进内存，不出现在指纹里。
        let fingerprint = BettboxClient.configFingerprint(forSource: .custom, customPath: good.path)
        XCTAssertTrue(fingerprint.hasPrefix("custom|custom|"))
        XCTAssertFalse(fingerprint.contains("s3cr3t"))
        XCTAssertEqual(BettboxClient.configFingerprint(forSource: .clashX), "missing|clashX")
        XCTAssertNotEqual(fingerprint, BettboxClient.configFingerprint(forSource: .bettbox))
    }

    func testProfileIsolationKeepsBettboxDefault() {
        let bettboxJSON = write("Library/Application Support/com.appshub.bettbox/config.json",
                                #"{"currentProfileId":"bb-profile","profiles":[{"id":"bb-profile","label":"机场 A"}]}"#)
        let bettbox = BettboxClient.profile(for: resolved(.bettbox, id: "bettbox", profileURL: bettboxJSON, kind: .bettboxJSON))
        XCTAssertEqual(bettbox, BettboxProfileInfo(id: "bb-profile", label: "机场 A"))

        // Bettbox 没有 profile 文件时沿用旧 fallback "default"，保证既有 group_watch 记录可继续命中。
        XCTAssertEqual(BettboxClient.profile(for: resolved(.bettbox)), .fallback)
        XCTAssertEqual(BettboxClient.profile(for: resolved(.bettbox)).id, "default")

        // 非 Bettbox 必须使用 :default 后缀，避免与 Bettbox 的 default 撞键。
        XCTAssertEqual(BettboxClient.profile(for: resolved(.clashX)).id, "clashx:default")
        XCTAssertEqual(BettboxClient.profile(for: resolved(.mihomoParty)).id, "mihomo-party:default")
        XCTAssertNotEqual(BettboxClient.profile(for: resolved(.flClash)).id, BettboxProfileInfo.fallback.id)

        // Clash Verge / Mihomo Party 的 profiles.yaml 当前项与名称。
        let profiles = write("verge/profiles.yaml", "current: uid-1\nprofiles:\n  - uid: uid-1\n    name: Verge Default\n")
        XCTAssertEqual(BettboxClient.profile(for: resolved(.clashVerge, profileURL: profiles, kind: .yamlCurrent)),
                       BettboxProfileInfo(id: "uid-1", label: "Verge Default"))

        // FlClash 的 config.json 读取 currentProfileId。
        let fl = write("fl/config.json", #"{"currentProfileId":"fl-1"}"#)
        XCTAssertEqual(BettboxClient.profile(for: resolved(.flClash, profileURL: fl, kind: .flClashJSON)).id, "fl-1")
    }

    func testGroupOrderExtractionFollowsTopLevelProxyGroups() {
        let text = """
        mixed-port: 7890
        proxy-groups:
          - name: "🚀 节点选择"
            type: select
            proxies:
              - Auto
          - name: Auto # 行尾注释
            type: url-test
            proxies:
              - NodeA
          - {name: Inline, type: select}
        proxies:
          - name: NotAGroup
        rules:
          - MATCH,🚀 节点选择
        """
        XCTAssertEqual(BettboxClient.groupOrder(inConfig: text), ["🚀 节点选择", "Auto"])
        XCTAssertTrue(BettboxClient.groupOrder(inConfig: "mixed-port: 7890\n").isEmpty)

        let client = try? BettboxClient.make(config: "external-controller: 127.0.0.1:9090\n" + text).get()
        XCTAssertEqual(client?.groupOrder, ["🚀 节点选择", "Auto"])
        XCTAssertEqual(client?.sourceId, "bettbox")
    }
}

